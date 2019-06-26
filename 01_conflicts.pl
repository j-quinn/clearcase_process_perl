#!C:/PROGRA~1/Rational/ClearCase/bin/ccperl.exe

###############################################################################
# 01_conflicts.pl -- Query ClearQuest for CRs for a stated release, find all
#                    branches containing the CR numbers, then examine the
#                    branches for the existence of zero branches, checkouts,
#                    branch conflicts, merge conflicts, and extended path
#                    errors.  Script will also create a ClearCase View for use
#                    in the examination process, set the view's config spec to
#                    the config spec identified by the branch query.  Script
#                    will then email the list of conflicts to the development
#                    team.
###############################################################################

use strict;

# dump hash contents to file 
use FindBin;
use Data::Dumper;

# allows for the use of command line flags
use Getopt::Std;
# common functions for build and release scripts
use CrProcess;

#
# CONSTANTS
#

my $CS = "cs.txt";


#
# Globals
#
my %CRs = ();
my %Elements = ();

# GetOpt variables
#   b = baseline
#   e = extra CRs for conflicts checking
#   q = quiet (do not email results)
#   t = target release
our( $opt_b, $opt_e, $opt_q, $opt_t );

# operating variables
my $ReleaseNum = "";
my $ReleaseBranch = "";
my $Baseline = "";
my $ViewOption = $CrProcess::VIEW_USE_EXISTING;
my $NoEmail = "";
# CRs that may not be in the "Resolved" state (or even the target release)
# that should be examined
my @ExtraCrs = ();

my $ConflictsReport = "";
my $FilesReport = "";

# keep track of whether an integration branch was created
my $EvaluateConfigSpec = 1;

# containers for delayed reporting
my %AtAtErrors = ();
my %DevelopersWithConflicts = ();

my $NumConflicts = 0;

###############################################################################
# Main Program Body
#
{
  getopts( "fqt:b:e:" );

  $ReleaseNum = $opt_t;
  &usage() unless $ReleaseNum;
  $Baseline = $opt_b;
  &usage() unless $Baseline;
  $NoEmail = $opt_q;
  @ExtraCrs = split( /,/, $opt_e );

  # check the two values entered to the script to prevent cut-and-paste errors
  if( $ReleaseNum eq $Baseline )
  {
    my $dieMsg = "Error: Target release and baseline values are the same.\n";
    $dieMsg .= "\tTarget release = " . $ReleaseNum . "\n";
    $dieMsg .= "\tBaseline = " . $Baseline . "\n";

    die $dieMsg;
  }

  # >>> Need to check that the passed target release is a valid option.
  if( $CrProcess::DEBUG & hex(1) )
  {
    print "\$Baseline = " . $Baseline . "\n";
    print "\$NoEmail = " . $NoEmail . "\n";
    print "\$ViewOption = " . $ViewOption . "\n";
    print "\$ReleaseNum = " . $ReleaseNum . "\n";
  }

  # create the ClearCase view to use to check for conflicts
  my $conflictsView = &CrProcess::createView( $ReleaseNum,
                                              $CrProcess::CONFLICTS,
                                              $CrProcess::VIEW_USE_EXISTING );

  # change to the conflicts view
  if( $conflictsView )
  {
    chdir "M:\\" . $conflictsView . "\\" . $CrProcess::VOB;
    if( $CrProcess::DEBUG & hex(1) )
    {
      print "Working Directory = ";
      system "pwd";
      print "Working View = ";
      system "cleartool pwv -short";
    }
  }
  else
  {
    die "Cannot access conflicts view.\n";
  }

  # The release config spec can change if a release integration branch is
  # created.
  while( $EvaluateConfigSpec )
  {
    $EvaluateConfigSpec = 0;

    # remove this iteration of the conflicts report
    if( $ConflictsReport )
    {
      my $cmd = "rm -f $ConflictsReport";
      if( $CrProcess::DEBUG & hex(1) )
      {
        print $cmd . "\n";
      }
      unless( $CrProcess::DEBUG & hex(8) )
      {
        system $cmd;
      }
    }

    # query the view for the list of branches and elements for the CRs
    &CrProcess::processCrList( $CrProcess::CONFLICTS,
                               $ReleaseNum,
                               \%CRs,
                               \@ExtraCrs );

    # find ClearCase branches for each CR
    &CrProcess::findBranches( \%CRs );

    # set view configspec to contain all branches
    &createConfigSpec( $CS, 1 );

    # Confirm existence of release directory and conflicts subdirectory.  Create
    # next iteration of conflicts report
    $ConflictsReport = &CrProcess::createReportFile( $ReleaseNum,
                                                     $CrProcess::CONFLICTS );

    # add config spec to conflicts report
    &createConfigSpec( $ConflictsReport, 0 );

    # query elements for each branch
    &CrProcess::findElements( \%CRs );

    # process database for conflicts

    # find "zero branches"
    &determineZeroBranches();

    # find checkouts
    &determineCheckouts();

    # find branch conflicts
    &determineBranchConflicts();
  }

  # find merge conflicts
  &determineMergeConflicts();

  # print @@ errors
  &reportAtAtErrors();

  # print list of all files changed for the CRs in this release
  &reportFileList();

  # lock the config spec
  unless( $CrProcess::DEBUG & hex(8) )
  {
    &lockBranches();
  }

  print "\nConflicts remaining: " . $NumConflicts . "\n";

  # Dump the contents of the CR hash to a text file
  if( $CrProcess::DEBUG & hex(10) )
  {
    open DATADUMP, ">$FindBin::Bin/01_dumpfile.txt" or die "Cannot open dump file: $!\n";
    print DATADUMP Dumper( \%CRs );
    close DATADUMP;
  }

  # display recipient list even if the email isn't being sent
  if( $CrProcess::DEBUG & hex(1) )
  {
    print "Sending conflicts email to recipients:\n";
    foreach( sort keys %DevelopersWithConflicts )
    {
      print "\t$_\n";
    }
    print "\n";
  }

  &sendConflictsEmail() unless $NoEmail;

  # update ClearQuest if the conflicts are clean
  unless( $NumConflicts )
  {
    print "Updating ClearQuest:\n\n";
    # Account for changes that may have been obsoleted during the conflicts
    # resolution process
    &CrProcess::findElements( \%CRs, "obsolete" );

    # review the CRs and elements
    &processDatabase();

    # create empty file for  files report
    $FilesReport = &CrProcess::createReportFile( $ReleaseNum, $CrProcess::FILES );

    # update ClearQuest CR records
    &CrProcess::processCrList( $CrProcess::FILES,
                               $ReleaseNum,
                               \%Elements );

    # update the files report
    &updateFilesReport();

    if( $CrProcess::DEBUG & hex(10) )
    {
      open DATADUMP, ">$FindBin::Bin/02_elements_dumpfile.txt" or die "Cannot open dump file: $!\n";
      print DATADUMP Dumper( \%Elements );
      close DATADUMP;

      open DATADUMP, ">$FindBin::Bin/02_CRs_dumpfile.txt" or die "Cannot open dump file: $!\n";
      print DATADUMP Dumper( \%CRs );
      close DATADUMP;
    }

    # send email containing branch and element information
    &sendFilesEmail() unless $NoEmail;
  }
}
#
# End Main Program Body
###############################################################################


#
# Subroutines
#


###############################################################################
# usage -- print the script usage information to the screen
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub usage
{
  print "Usage:  01_conflicts.pl -t <target_release> -b <baseline> [-q]";
  print " [-e <extra_crs>]\n";
  print "Where:\n";
  print "\ttarget_release = ClearQuest target release string\n";
  print "\tbaseline = Label to be used as a baseline for the release.  This\n";
  print "\t\tmay not be the preceding release.\n";
  print "\t-q = do not send email notification\n";
  print "\t-e = comma-separated list of additional CRs to be evaluated\n";

  exit( -1 );
}


###############################################################################
# lockBranches -- lock the branches of the config spec to prevent them from
#                 being modified
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub lockBranches
{

  print "\nLocking config spec:\n\n";

  # check to see which VOBs have had changes applied
  my @changedVobs = ();
  &CrProcess::findChangedVobs( $ReleaseNum, \@changedVobs );

  # only perform operations on the list of VOBs whose contents have been
  # modified in this release
  foreach my $vob ( @changedVobs )
  {
    chdir "../$vob";

    if( $CrProcess::DEBUG & hex(1) )
    {
      system "pwd";
    }

    # Walk through the CR database from CR to branch.  Check each branch to see
    # if there are still conflicts associated with the branch.  If no further
    # conflicts exist, check if the branch is already locked and lock the
    # branch if not.
    foreach my $cr ( sort keys %CRs )
    {
      foreach my $branch ( sort keys %{$CRs{$cr}->{branches}} )
      {
        # check whether branch exists in this VOB
        my $descriptionCmd = "cleartool describe -short brtype:";
        $descriptionCmd .= $branch . " 2>&1";

        my $result = `$descriptionCmd`;
        next if( $result =~ /error/i );

        # don't lock the integration branch
        next if( $branch =~ /intg/ );

        # don't lock if conflicts exist on the branch
        if( ${$CRs{$cr}->{branches}{$branch}->{has_conflicts}} )
        {
          if( $CrProcess::DEBUG & hex(1) )
          {
            print "Branch " . $branch . " has conflicts and will not be locked\n";
          }

          next;
        }

        if( ${$CRs{$cr}->{branches}{$branch}->{is_locked}} )
        {
          if( $CrProcess::DEBUG & hex(1) ){
            print "Branch " . $branch . " is already locked.\n";
          }
        }
        else
        {
          print "Locking branch " . $branch . "\n";
          &CrProcess::lockBranch( $CrProcess::LOCK, $branch );
        } # branch lock check
      } # check each branch for current CR
    } # check each CR
  }  # changed VOBs
}


###############################################################################
# createConfigSpec -- Set the conflicts view config spec to include all branches
#                  indicated by the target release's CRs
#
# parameters
#   $outfile -- location of a text file to contain the config spec
#   $setcs   -- if nonzero, sets the current views configspec to the contents
#               of $outfile
#
# returns
#   NONE
###############################################################################
sub createConfigSpec
{
  my ( $outfile, $setcs ) = @_;

  my $multipleBranches = "";

  # remove old config spec file if it exists and will be set for a view
  if( -e $outfile && $setcs )
  {
    unlink $outfile;
  }

  open( CONFIGSPEC, ">$outfile" )
  or die "Cannot create configspec file $outfile: $!\n";
  print CONFIGSPEC "# config spec for target release " . $ReleaseNum;
  print CONFIGSPEC "\n\n";
  print CONFIGSPEC "element * CHECKEDOUT\n\n";

  # exclude library files from the config spec
  foreach my $excludeFile ( @CrProcess::LIBRARY_EXCLUDES )
  {
    print CONFIGSPEC "element " . $excludeFile . " -none\n";
  }
  if( scalar(@CrProcess::LIBRARY_EXCLUDES) )
  {
    print CONFIGSPEC "\n";
  }

  # Build the config spec for the conflicts view by retrieving the information
  # from the CR database.  There may be multiple branches for each CR.
  foreach my $cr ( sort keys %CRs )
  {
    foreach my $branch ( sort keys %{$CRs{$cr}->{branches}} )
    {
      # check branch name for name of release branches.  These need to exist at
      # the end of the config spec.
      if( $branch =~ /(\w+)_(\w+?)\.(\w+?)_/ )
      {
        my $parentBranch = $1;

        $parentBranch = uc( $parentBranch ) unless ( $parentBranch eq "main" );

        # initialize the release branch
        $ReleaseBranch = $parentBranch unless $ReleaseBranch;

        if( $CrProcess::DEBUG & hex(1) )
        {
          print "\$parentBranch = " . $parentBranch . "\n";
        }

        # there can be only one release branch in the config spec 
        # THIS INCLUDES /main!!!  The /main branch in ClearCase cannot be
        # renamed.  A decision was made to use /main as the Viking product
        # branch to prevent having to edit the default config spec to include
        # the branch rule and mkbranch command.

        # release branches can either be upper-case or "main".
        if( ($parentBranch eq "main") && !($ReleaseBranch eq $parentBranch) )
        {
          $multipleBranches = $parentBranch;
        }
        elsif( !($parentBranch eq "main") && !($ReleaseBranch eq uc($parentBranch)) )
        {
          $multipleBranches = uc( $parentBranch );
        }
      } # end parent branch check

      print CONFIGSPEC "element * .../" . $branch . "/LATEST\n";
    } # end check of braches for current CR
  } # end check of all CRs

  # separate developer branches from integration and product branches
  print CONFIGSPEC "\n";

  if( $multipleBranches )
  {
    print CONFIGSPEC "#WARNING:  Release branches exist for more than one ";
    print CONFIGSPEC "target:\n#\t" . $multipleBranches;
    print CONFIGSPEC "\n#\t" . $ReleaseBranch . "\n\n";
  }

  # the /main branch does not have a parent branch so the ".../" path wildcard
  # is not needed.
  if( $ReleaseBranch eq "main" )
  {
    print CONFIGSPEC "element * /main/LATEST\n\n";
  }
  else
  {
    print CONFIGSPEC "element * .../" . $ReleaseBranch . "/LATEST\n\n";
  }

  if( $Baseline )
  {
    print CONFIGSPEC "element * " . $Baseline . "\n\n";
  }

  close CONFIGSPEC;

  # set the config spec
  if( $setcs )
  {
    system "cleartool", "setcs", $outfile;
    unlink $outfile;
  }
}


###############################################################################
# determineZeroBranches -- identifies elements for which the development branch
#                          contains only the zeroth element
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub determineZeroBranches
{
  my %zeroBranches = ();

  print "\nFinding zero branches:\n\n";

  # The database contains at least one change request.  The change request may
  # contain multiple branches, each branch may contain multiple elements.  Walk
  # through the database, CRs to branches to elements, and check each element
  # for the conflict condition.
  foreach my $cr ( sort keys %CRs )
  {
    # get branches for each CR
    foreach my $branch ( sort keys %{$CRs{$cr}->{branches}} )
    {

      if( $CrProcess::DEBUG & hex(1) )
      {
        print "Determining zero branches for branch " . $branch . "\n";
      }

      # get the list of elements from the branch
      foreach my $element ( @{$CRs{$cr}->{branches}{$branch}->{elements}} )
      {
        my $tempElement = $element;

        # test this element to see whether the branch is a zero branch
        if( &CrProcess::isZeroBranch($branch, $tempElement) )
        {

          my @lsvtreePath = split( "@@", $tempElement );
          $tempElement = $lsvtreePath[0];

          if( $#lsvtreePath > 1 )
          {
            foreach( 2..$#lsvtreePath )
            {
              $tempElement .= "@@" . $lsvtreePath[$_ - 1];
            }
          }

          push( @{$zeroBranches{$branch}}, $tempElement );
          # flag branch to be skipped during lock process
          ${ $CRs{$cr}->{branches}{$branch}->{has_conflicts} } = 1;

          $NumConflicts++;
        }
      } # iterate through elements
    } # iterate through branches
  } # iterate through CRs

  # output to conflicts file
  open( OUTFILE, ">>$ConflictsReport" )
  or die "Cannot open output file $ConflictsReport for checkouts report: $!\n";
  print OUTFILE "ZERO BRANCHES:\n\n";

  foreach my $branch ( sort keys %zeroBranches )
  {
    # add developer to list of recipients
    if( !($branch =~ /intg/) &&
        ($branch =~ /_(([a-z\.\-]+)?)_(\d{$CrProcess::CR_NUM_LEN})/) )
    {
      $DevelopersWithConflicts{ $1 } = 1;
    }

    if( $CrProcess::DEBUG & hex(1) )
    {
      print $branch . "\n";
    }
    print OUTFILE $branch . "\n";

    foreach my $element ( @{$zeroBranches{$branch}} )
    {
      # trim non-clearcase path information from element listing
      $element =~ s/(.*?)(\\[A-Z_].*)/$2/;

      if( $CrProcess::DEBUG & hex(1) ){
        print "\t" . $element . "\n";
      }
      print OUTFILE "\t" . $element . "\n";
    } # check elements for this branch
    print OUTFILE "\n";
  } # check all branches

  print OUTFILE "\n";
  close OUTFILE;
}


###############################################################################
# determineCheckouts -- identifies elements still checked out for each branch
#                       in the release
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub determineCheckouts
{
  my %checkouts = ();

  print "\nFinding checkouts:\n\n";

  # check to see which VOBs have had changes applied
  my @changedVobs = ();
  &CrProcess::findChangedVobs( $ReleaseNum, \@changedVobs );

  foreach my $vob ( @changedVobs )
  {
    chdir "../$vob";

    if( $CrProcess::DEBUG & hex(1) )
    {
      system "pwd";
    }


    # The database contains at least one change request.  The change request may
    # contain multiple branches, each branch may contain multiple elements.  Walk
    # through the database, CRs to branches to elements, and check each element
    # for the conflict condition.
    foreach my $cr ( sort keys %CRs )
    {
      foreach my $branch ( sort keys %{$CRs{$cr}->{branches}} )
      {
        # check whether branch exists in this VOB
        my $descriptionCmd = "cleartool describe -short brtype:";
        $descriptionCmd .= $branch . " 2>&1";

        my $result = `$descriptionCmd`;
        next if( $result =~ /error/i );

        if( $CrProcess::DEBUG & hex(1) )
        {
          print "Determining checkouts for branch " . $branch . "\n";
        }

        # Execute and evaluate the ClearCase "list checkouts" command
        my $checkoutsCmd = "cleartool lsco -all -short -brtype " . $branch;
        open( CHECKOUTS, "$checkoutsCmd |" )
        or die "Cannot open command cleartool lsco: $!\n";
        foreach my $element ( <CHECKOUTS> )
        {
          # remove whitespace
          $element =~ s/\x0d//g;
          $element =~ s/\x0a//g;

          push( @{$checkouts{$branch}}, $element );
          # flag branch to be skipped during lock process
          ${ $CRs{$cr}->{branches}{$branch}->{has_conflicts} } = 1;

          $NumConflicts++;
        } # check all elements
        close CHECKOUTS;
      } # end check all branches
    } # end check all CRs
  } # end check of changed VOBs

  open( OUTFILE, ">>$ConflictsReport" )
  or die "Cannot open output file $ConflictsReport for checkouts report: $!\n";
  print OUTFILE "CHECKOUTS:\n\n";

  foreach my $branch ( sort keys %checkouts )
  {
    # add developer to list of recipients
    if( !($branch =~ /intg/) &&
        ($branch =~ /_(([a-z\.\-]+)?)_(\d{$CrProcess::CR_NUM_LEN})/) ){
      $DevelopersWithConflicts{ $1 } = 1;
    }

    if( $CrProcess::DEBUG & hex(1) )
    {
      print $branch . "\n";
    }
    print OUTFILE $branch . "\n";

    foreach my $element ( @{$checkouts{$branch}} )
    {
      # trim non-clearcase path information from element listing
      $element =~ s/(.*?)(\\[A-Z_].*)/$2/;

      if( $CrProcess::DEBUG & hex(1) )
      {
        print "\t" . $element . "\n";
      }
      print OUTFILE "\t" . $element . "\n";
    } # all elements for this branch
    print OUTFILE "\n";
  } # all branches

  print OUTFILE "\n";
  close OUTFILE;
}


###############################################################################
# determineBranchConflicts -- identfies elements that have more than one branch
#                             associated with it
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub determineBranchConflicts
{
  my %elements = ();

  print "\nFinding branch conflicts:\n\n";

  # walk through the CRs database and add the element names to the elements
  # hash as keys and the branches as values.  
  foreach my $cr ( sort keys %CRs )
  {
    foreach my $branch ( sort keys %{$CRs{$cr}->{branches}} )
    {
      foreach my $element ( @{$CRs{$cr}->{branches}{$branch}->{elements}} )
      {
        my @fullPath = split( '@@', $element );

        # "@@" errors are a special case.  Store them for later printout.
        if( scalar(@fullPath) > 2 )
        {
          push( @{$AtAtErrors{$branch}}, $element );
          # flag branch to be skipped during lock process
          ${ $CRs{$cr}->{branches}{$branch}->{has_conflicts} } = 1;

          $NumConflicts++;
          next;
        }

        push @{ $elements{@fullPath[0]}->{branches} }, $branch;
        # initialize the parallel toggle
        ${ $elements{@fullPath[0]}->{is_parallel} } = 0;
      } # end check of all elements for this branch
    } # end check of all branches for this CR
  } # end check of all change requests

  open( OUTFILE, ">>$ConflictsReport" )
  or die "Cannot open output file $ConflictsReport: $!\n";
  print OUTFILE "BRANCH CONFLICTS:\n\n";

  # walk through the elements hash and print out the elements that have more
  # than one branch associated with it
  foreach my $element ( sort keys %elements )
  {
    if( scalar @{ $elements{$element}->{branches} } > 1 )
    {
      # create integration branch where needed and add the integration branch
      # to the list of branches on the element
      &processParallelConflicts( $element, \%elements );

      # modify the element path for printout but do not change the way the
      # element is stored in the hash
      {
        my $tempElement = $element;
        # trim non-clearcase path information from element listing
        $tempElement =~ s/(.*?)(\\[A-Z_].*)/$2/;

        print OUTFILE $tempElement . "\n";
      }

      $NumConflicts++;

      foreach my $branch ( @{$elements{$element}->{branches}} )
      {
        foreach my $cr ( sort keys %CRs )
        {
          if( exists($CRs{$cr}->{branches}{$branch}) )
          {
            # flag branch to be skipped during lock process
            ${ $CRs{$cr}->{branches}{$branch}->{has_conflicts} } = 1;
          }
        }

        # add developer to list of recipients
        if( !($branch =~ /intg/) &&
            ($branch =~ /_(([a-z\.\-]+)?)_(\d{$CrProcess::CR_NUM_LEN})/) )
        {
          $DevelopersWithConflicts{ $1 } = 1;
        }

        print OUTFILE "\t" . $branch . "\n";
      } # end branch check
      print OUTFILE "\n";
    } # more than one branch exists for this element
  } # examine each element in this release

  print OUTFILE "\n";
  close OUTFILE;
}


###############################################################################
# processParallelConflicts -- run through list of branch conflicts and check
#            for parallel conflicts.  Create integration branch where parallel
#            conflicts exists.
#
# parameters
#   $element -- VOB-relative path to the element being checked for parallels
#   $branchesPtr -- pointer to a hash containing the list of branch conflicts
#
# returns
#   zero if no new branches were created, non-zero if an integration branch was
#   created.
###############################################################################
sub processParallelConflicts
{
  my ( $element, $branchesPtr ) = @_;

  my %vobs = ();
  my $vob = "";

  # check to see which VOBs have had changes applied
  my @changedVobs = ();
  &CrProcess::findChangedVobs( $ReleaseNum, \@changedVobs );

  foreach $vob ( @changedVobs )
  {
    ${$vobs{$vob}->{integrationBranchExists}} = 0;
  }

  # examine each element's version tree listing to see if there are more than
  # one branch in this release on the element
  foreach my $branch ( @{$$branchesPtr{$element}->{branches}} )
  {

    # check for parallel conflict and create integration branch if it is
    my $cmd = "cleartool lsvtree -branch .../" . $branch . " \"" . $element;
    $cmd .= "\"";
    open( LS, "$cmd |" ) or die "Cannot open cleartool lsvtree: $!\n";
    foreach my $listing ( <LS> )
    {
      if( $listing =~ /$ReleaseBranch\\$branch$/ )
      {
        # set the parallel toggle
        ${ $$branchesPtr{$element}->{is_parallel} } = 1;

        if( $CrProcess::DEBUG & hex(1) )
        {
          print $listing;
          print "\n\nPotential parallel on element " . $element . "\n\n";
        }
      }

      foreach my $i ( 0..$#{$$branchesPtr{$element}->{branches}} )
      {
        my $secondBranch = @{ $$branchesPtr{$element}->{branches} }[$i];

        if( $CrProcess::DEBUG & hex(1) )
        {
          print "Checking branch " . $branch . " against " . $secondBranch . "\n";
        }

        next if( $secondBranch eq $branch );

        if( $listing =~ /$branch\\$secondBranch/ )
        {
          # reset the parallel toggle
          ${ $$branchesPtr{$element}->{is_parallel} } = 0;

          if( $CrProcess::DEBUG & hex(1) )
          {
            print $listing;
            print "Conflict on element " . $element . " is serial\n";
          }
        }
      } # end branch check current vtree listing

      last unless( ${ $$branchesPtr{$element}->{is_parallel} } );
    } # end examination of vtree on current element
    close LS;
  } # done checking all branches for this element

  # parallel branch conflict exists, create integration branch
  if( ${$$branchesPtr{$element}->{is_parallel}} == 1 )
  {
    # chdir to the correct VOB
    if( $element =~ /\\([A-Z_]+?)\\.*$/ )
    {
      $vob = $1;
      chdir "../$vob";
    }

    # check to see if branch type exists and create it if it doesn't
    unless( ${$vobs{$vob}->{integrationBranchExists}} )
    {
      my $descriptionCmd = "cleartool describe -short brtype:";
      $descriptionCmd .= $CrProcess::IntegrationBranch;

      my $result = `$descriptionCmd`;
      # if the branch type is not found, the report will be sent to STDERR and
      # $result will be empty
      unless( $result )
      {
        system "cleartool", "mkbrtype", "-nc", $CrProcess::IntegrationBranch;
        ${ $vobs{$vob}->{integrationBranchExists} } = 1;
      }
    }

    # check to see if the branch instance exists on this element
    # and create it if it doesn't
    my $cmd = "cleartool lsvtree -branch \".../" . $CrProcess::IntegrationBranch . "\" \"";
    $cmd .= $element . "\"";
    if( $CrProcess::DEBUG & hex(1) )
    {
      print $cmd . "\n";
    }

    my $result = `$cmd`;
    unless( $result )
    {
      if( $CrProcess::DEBUG & hex(1) )
      {
        print "Creating integration branch on element ";
        print $element . "\n";
      }

      # $Baseline will not exist on new elements.  Determine whether the
      # label exists on the element and use /main/LATEST if it does not
      my $labelExists = 0;
      $cmd = "cleartool lsvtree $element";
      open( LSVTREE, "$cmd |" ) or die "Cannot execute command $cmd: $!\n";
      foreach my $line ( <LSVTREE> )
      {
        if( $line =~ /$Baseline/ )
        {
          $labelExists = 1;
        }
      }
      close LSVTREE;

      $cmd = "cleartool mkbranch -nc -nco -ver ";
      if( $labelExists )
      {
        $cmd .= $Baseline;
      }
      else
      {
        $cmd .= '/main/LATEST';
      }

      $cmd .= " " . $CrProcess::IntegrationBranch . " " . $element;
      if( $CrProcess::DEBUG & hex(1) )
      {
        print $cmd . "\n";
      }

      # create the integration branch
      system $cmd;

      # release config spec has been created already and will not contain the
      # newly created branch.
      $EvaluateConfigSpec = 1;
      print "Integration branch created, re-evaluating the config spec\n";

      # add the integration branch to the list of branches on this element
      push( @{$$branchesPtr{$element}->{branches}}, $CrProcess::IntegrationBranch );
    } # end check for existence of integration branch on this element
  } # end integration branch creation
}


###############################################################################
# determineMergeConflicts -- Identify branches that are not able to be merged
#                directly to the Product Release branch.
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub determineMergeConflicts
{
  my %merges = ();

  print "\nFinding merge conflicts:\n\n";

  # walk through the CRs database and add the element names to the elements
  # hash as keys and the branches as values.  
  foreach my $cr ( sort keys %CRs )
  {
    foreach my $branch ( sort keys %{$CRs{$cr}->{branches}} )
    {
      # integration branch will always be created from /LATEST
      next if( $branch =~ /intg/ );

      foreach my $element ( @{$CRs{$cr}->{branches}{$branch}->{elements}} )
      {

        # progress indicator
        if( $CrProcess::DEBUG & hex(1) )
        {
          print "\n" . $element . "\n";
        }
        else
        {
          print ".";
        }

        # test the merge and don't create a logfile
        my $cmd = "cleartool findmerge \"" . $element . "/LATEST ";
        $cmd .= "\" -fversion .../" . $ReleaseBranch . "/LATEST -directory";
        $cmd .= " -nxname -whynot -nzero -print -log /dev/null";

        open( FINDMERGE, "$cmd |" )
        or die "Cannot open cleartool findmerge $cmd: $!\n";
        foreach my $line ( <FINDMERGE> )
        {
          next if( $line =~ /^No merge/ );

          # remove whitespace
          $line =~ s/\x0d//g;
          $line =~ s/\x0a//g;

          push( @{$merges{$branch}}, $line );
          # flag branch to be skipped during lock process
          ${ $CRs{$cr}->{branches}{$branch}->{has_conflicts} } = 1;

          $NumConflicts++;
        } # end execution of ClearCase findmerge command
        close FINDMERGE;
      } # end merge conflict check for this element
    } # check all branches
  } # check all CRs

  open( OUTFILE, ">>$ConflictsReport" )
  or die "Cannot open output file $ConflictsReport: $!\n";
  print OUTFILE "MERGE CONFLICTS:\n\n";

  # walk through the local hash and process the contents for the conflicts
  # report
  foreach my $branch ( sort keys %merges )
  {
    # add developer to list of recipients
    if( !($branch =~ /intg/) &&
        ($branch =~ /_(([a-z\.\-]+)?)_(\d{$CrProcess::CR_NUM_LEN})/) )
    {
      $DevelopersWithConflicts{ $1 } = 1;
    }

    if( $CrProcess::DEBUG & hex(1) )
    {
      print "\n" . $branch . "\n";
    }
    print OUTFILE $branch . "\n";

    foreach my $element ( @{$merges{$branch}} )
    {
      # trim non-clearcase path information from element listing
      $element =~ s/(.*?)(\\[A-Z_].*)/$2/;

      if( $CrProcess::DEBUG & hex(1) )
      {
        print "\t" . $element . "\n";
      }
      print OUTFILE "\t" . $element . "\n";
    }
    print OUTFILE "\n";
  }

  print "\n";
  print OUTFILE "\n";
  close OUTFILE;
}


###############################################################################
# reportAtAtErrors -- Reports elements that are not visible in the current
#                     config spec except by extended path.  
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub reportAtAtErrors
{
  open( OUTFILE, ">>$ConflictsReport" )
  or die "Cannot open output file $ConflictsReport: $!\n";
  print OUTFILE "@@ CONFLICTS:\n\n";

  # process the hash for extended path ("@@") conflicts and print the branch
  # and elements of the branch to the conflicts report
  foreach my $branch ( sort keys %AtAtErrors )
  {
    # add developer to list of recipients
    if( !($branch =~ /intg/) &&
        ($branch =~ /_(([a-z\.\-]+)?)_(\d{$CrProcess::CR_NUM_LEN})/) )
    {
      $DevelopersWithConflicts{ $1 } = 1;
    }

    if( $CrProcess::DEBUG & hex(1) )
    {
      print "\n" . $branch . "\n";
    }
    print OUTFILE $branch . "\n";

    foreach my $element ( @{$AtAtErrors{$branch}} )
    {
      # trim non-clearcase path information from element listing
      $element =~ s/(.*?)(\\[A-Z_].*)/$2/;

      if( $CrProcess::DEBUG & hex(1) )
      {
        print "\n" . $element . "\n";
      }
      print OUTFILE "\t" . $element . "\n";
    } # end element processing for this branch
    print OUTFILE "\n";
  } # end examination of all branches in the hash

  print "\n";

  print OUTFILE "\n";
  close OUTFILE;
}


###############################################################################
# reportFileList -- Reports all files containing instances of branches of CRs
#                   in this release
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub reportFileList
{
  my %elements = ();

  open( OUTFILE, ">>$ConflictsReport" )
  or die "Cannot open output file $ConflictsReport: $!\n";
  print OUTFILE "ALL FILES:\n\n";

  # get all elements modified in this release by traversing the data structure
  # to find each element for each branch for each CR
  foreach my $cr ( sort keys %CRs )
  {
    foreach my $branch ( sort keys %{$CRs{$cr}->{branches}} )
    {
      foreach my $element ( @{$CRs{$cr}->{branches}{$branch}->{elements}} )
      {
        my $path = $element;

        # strip the ClearCase extended path information
        $path =~ s/\@\@.*//;

        $elements{$path} = 1;
      } # elements
    } # branches
  } # CRs

  # the local elements hash has the list of files that were changed in this
  # release.  Print this information to the conflicts report.
  foreach my $path ( sort keys %elements )
  {
    # trim non-clearcase path information from element listing
    $path =~ s/(.*?)(\\[A-Z_].*)/$2/;

    if( $CrProcess::DEBUG & hex(1) )
    {
      print $path . "\n";
    }

    print OUTFILE $path . "\n";
  }

  print OUTFILE "\n";
  close OUTFILE;
}


###############################################################################
# sendConflictsEmail -- Send email to developers who have outstanding conflicts
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub sendConflictsEmail
{

  print "\nSending " . $CrProcess::CONFLICTS . " email:\n\n";

  # subject of email is the release number, "conflicts", and iteration of
  # the script run
  my $subject = $ReleaseNum . " " . $CrProcess::CONFLICTS . " ";

  # Subject of email is base name of conflicts file or "conflicts clean" if
  # the number of conflicts remaining is zero
  if( $ConflictsReport =~ /(.*?)_$CrProcess::CONFLICTS(\d+)/ )
  {
    if( $NumConflicts )
    {
      $subject .= $2 . "\n";
    }
    else
    {
      # add the build engineer to the recipients hash to force send to the
      # software development team
      $DevelopersWithConflicts{ $CrProcess::BUILD_ENG } = 1;
      $subject .= "are clean\n";
    }
  }

  # send conflicts email
  &CrProcess::sendEmail( $ConflictsReport,
                         \%DevelopersWithConflicts,
                         $subject );
}


###############################################################################
# processDatabase -- for each CR number, get the element paths for each branch
#                    and add as values to the Elements hash.  Get the list of
#                    obsolete elements and add to the Elements hash if the
#                    element also contains an instance of the integration
#                    branch.
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub processDatabase
{

  # The database contains at least one change request.  The change request may
  # contain multiple branches, each branch may contain multiple elements.  Walk
  # through the database, CRs to branches to elements, and prepare the element
  # name for write to the ClearQuest records and files report.
  foreach my $cr ( sort keys %CRs )
  {
    foreach my $branch ( sort keys %{$CRs{$cr}->{branches}} )
    {
      foreach my $element ( @{$CRs{$cr}->{branches}{$branch}->{elements}} )
      {
        $element =~ s/(.*?)(\\[A-Z_].*?)(\@\@.*)/$2/;

        # handle parallel branch conflicts by adding the element path if an
        # integration branch exists on the element
        if( $branch =~ /.obs/ )
        {
          foreach my $integrationElement ( @{$CRs{intg}->{branches}{$CrProcess::IntegrationBranch}->{elements}} )
          {
            # get the simple VOB-relative path
            $integrationElement =~ s/(.*?)(\\[A-Z_].*?)(\@\@.*)/$2/;
            # add the element if it matches the integration branch element
            if( $element eq $integrationElement )
            {
              $Elements{$CRs{$cr}->{cr_id}}{$element} = 1;
            }
          }
        }
        else
        {
          $Elements{$CRs{$cr}->{cr_id}}{$element} = 1;
        } # is obsolete branch?
      } # end all elements
    } # end all branches
  } # end all CRs
}


###############################################################################
# updateFilesReport -- output contents of the hash to the Files report
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub updateFilesReport
{
  # output to files report
  open( FILES, ">>$FilesReport" ) or die "Cannot open file $FilesReport: $!\n";
  # iterate through the Elements hash
  foreach my $crId ( sort keys %Elements )
  {
    next if( $crId =~ /integration/ );
    print FILES $crId . "\n";
    foreach my $element ( sort keys %{$Elements{$crId}} )
    {
      print FILES "\t" . $element . "\n";
    }
    print FILES "\n";
  }
  close FILES;
}


###############################################################################
# sendFilesEmail -- send email containing branch and element information
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub sendFilesEmail
{
  print "\nSending " . $CrProcess::FILES . " email:\n\n";

  # subject of email is the release number, type of script, and iteration of
  # the script run
  my $subject = $ReleaseNum . " " . $CrProcess::FILES . " ";
  if( $FilesReport =~ /(.*?)_$CrProcess::FILES(\d+)/ )
  {
      $subject .= $2 . "\n";
  }

  # send conflicts email
  &CrProcess::sendEmail( $FilesReport,
                         {},
                         $subject );
}
