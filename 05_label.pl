#!C:/PROGRA~1/Rational/ClearCase/bin/ccperl.exe

###############################################################################
# 05_label.pl -- Check in merged elements, apply label to release branches, and
#                compare completed label against developer config spec.
###############################################################################

use strict;

# dump hash contents to file 
use FindBin;

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

# GetOpt variables
#   q = quiet (do not email results)
#   t = target release
our( $opt_q, $opt_t );

# operating variables
my $ReleaseNum = "";
my $NoEmail = "";

my $LabelReport = "";
my $MergeView = "";
my $MergeViewConfigSpec = "";
my $MergeVobRoot = "";
my $LabelView = "";
my $LabelVobRoot = "";
my $ConflictsView = "";

###############################################################################
# Main Program Body
#
{
  getopts( "qt:" );

  $ReleaseNum = $opt_t;
  &usage() unless $ReleaseNum;
  $NoEmail = $opt_q;

  # do not recreate the Merge view
  $MergeView = &CrProcess::createView( $ReleaseNum,
                                       $CrProcess::MERGE,
                                       $CrProcess::VIEW_USE_EXISTING ); 

  if( $MergeView )
  {
    $MergeVobRoot = "M:\\" . $MergeView . "\\" . $CrProcess::VOB;

    chdir $MergeVobRoot;
    if( $CrProcess::DEBUG & hex(1) )
    {
      print "Working Directory = ";
      system "pwd";
      print "Working View = ";
      system "cleartool pwv -short";
    }
  }

  $MergeViewConfigSpec = `cleartool catcs`;

  # Create next iteration of build report
  $LabelReport = &CrProcess::createReportFile( $ReleaseNum, $CrProcess::LABEL );

  print "Checking in merged files...\n\n";
  &checkInFiles();

  # this operation changes the current directory to the label view
  &createLabelView();

  # set the label view configspec to match the merge view config spec
  &setLabelViewConfigSpec( "merge" );

  # iterate through the list of VOBs and label development VOBs
  my $result = &getVobList();

  # set the label view configspec to the main line
  &setLabelViewConfigSpec( "main" );

  unless( $result )
  {
    # apply labels to the VOBs that do not branch (documents, scm, etc.)
    $result = &createMainlineLabels();
  }

  # set the label view configspec to the release label
  &setLabelViewConfigSpec( "release" );

  unless( $result )
  {
    print "Comparing label against conflicts view...\n\n";
    &verifyLabel();
  }

  &sendLabelEmail() unless $NoEmail;
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
  print "Usage:  05_label.pl -t <target_release> [-q]\n";
  print "Where:\n";
  print "\ttarget_release = ClearQuest target release string\n";
  print "\t-q = do not send email notification\n";

  exit( -1 );
}


###############################################################################
# createLabelView -- Create a new view to contain just the label so that a
#                    comparison can be done between the label and the original
#                    release config spec without modifying the existing view.
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub createLabelView
{
  # re-create the label view
  $LabelView = &CrProcess::createView( $ReleaseNum,
                                       $CrProcess::LABEL,
                                       $CrProcess::VIEW_FORCE_RECREATE ); 

  # build the path to the label view
  if( $LabelView )
  {
    $LabelVobRoot = "M:\\" . $LabelView . "\\" . $CrProcess::VOB;

    chdir $LabelVobRoot;
    if( $CrProcess::DEBUG & hex(1) )
    {
      print "Working Directory = ";
      system "pwd";
      print "Working View = ";
      system "cleartool pwv -short";
    }
  }
}


###############################################################################
# checkInFiles -- check in the merged files
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub checkInFiles
{
  # >>> Cygwin sort command syntax.  This will fail in a DOS shell
  my $cmd = "cleartool lsco -all -short -cview | sort -r";
  if( $CrProcess::DEBUG & hex(1) )
  {
    print $cmd . "\n";
  }

  # check to see which VOBs have had changes applied
  my @changedVobs = ();
  &CrProcess::findChangedVobs( $ReleaseNum, \@changedVobs );

  # files will only need to be checked in for VOBs that have changed.  Do not
  # search for checked out files in other VOBs.
  foreach my $vob ( @changedVobs )
  {
    chdir "../$vob";

    if( $CrProcess::DEBUG & hex(1) )
    {
      system "pwd";
    }

    unless( $CrProcess::DEBUG & hex(8) )
    {
      open( LSCO, "$cmd |" ) or die "Cannot execute command $cmd: $!\n";
      foreach my $line ( <LSCO> )
      {
        # correct slashes
        $line =~ s/\\/\//g;

        # execute the ClearCase checkin command on the current element
        my $checkinCmd = "cleartool ci -nc " . $line;
        if( $CrProcess::DEBUG & hex(1) )
        {
          print $checkinCmd . "\n";
        }

        system $checkinCmd;
      }
      close( LSCO );
    }
  }

  # check to make sure that everything was checked in
  foreach my $vob ( @changedVobs )
  {
    my $checkouts = `$cmd`;
    die "The following checkouts still exist:\n$checkouts\n" if $checkouts;
  }
}


###############################################################################
# getVobList -- get the list of all VOBs.  Pass the names of development VOBs
#               to the label application subroutine
#
# parameters
#   NONE
#
# returns
#   integer value, zero if label was applied, non-zero if there were errors in
#   the application step
###############################################################################
sub getVobList
{
  my $returnVal = 0;

  # Label all vobs except test VOBs
  my $cmd = "cleartool lsvob -short";
  open( VOBS, "$cmd |" ) or die "Cannot open cleartool lsvob: $!\n";
  foreach my $vob ( <VOBS> )
  {
    # skip test vobs
    next if( $vob =~ /_TEST_/ );
    # skip Controls group's VOB
    next if( $vob =~ /$CrProcess::CONTROLS_VOB/ );
    # skip the Documents VOB and handle separately
    next if( $vob =~ /$CrProcess::DOCS_VOB/ );
    # skip the SCM VOB and handle separately
    next if( $vob =~ /$CrProcess::SCM_VOB/ );

    $vob =~ s/\\//g;

    $vob =~ s/\x0d//g;
    $vob =~ s/\x0a//g;

    $returnVal = &labelOneVob( $vob );
    die "Label operation failed, check error logs.\n" if $returnVal;
  }
  close VOBS;
  return $returnVal;
}


###############################################################################
# labelOneVob -- apply the release label to the specified VOB
#
# parameters
#   NONE
#
# returns
#   integer value, zero if label was applied, non-zero if there were errors in
#   the application step
###############################################################################
sub labelOneVob
{
  my ( $vob ) = @_;

  my $lbTypeExists = 0;
  my $returnVal = 0;
  my $outfile = "mklabel.out";

  chdir "../$vob";

  if( $CrProcess::DEBUG & hex(1) )
  {
    system "pwd";
  }

  # check to see if the label already exists
  my $cmd = "cleartool lstype -obsolete -kind lbtype -short";
  open CMD, ( "$cmd |" ) or die "Cannot execute command $cmd: $!\n";
  foreach my $line ( <CMD> )
  {
    if( $line =~ /$ReleaseNum/ )
    {
      if( $CrProcess::DEBUG & hex(1) )
      {
        print $line;
      }
      $lbTypeExists = 1;
    }
  }
  close( CMD );

  # create the label type unless it already exists in the VOB
  unless( $lbTypeExists )
  {
    print "Creating label type " . $ReleaseNum . "\n";
    # create the label type
    $cmd = "cleartool mklbtype -nc " . $ReleaseNum;
    if( $CrProcess::DEBUG & hex(1) )
    {
      print $cmd . "\n";
    }

    unless( $CrProcess::DEBUG & hex(8) )
    {
      system $cmd;
    }
  }

  # create the label creation command.  Don't show progress unless specified.
  if( $CrProcess::DEBUG & hex(1) )
  {
    $cmd = "cleartool mklabel -recurse -nc " . $ReleaseNum . " . 2>&1 | tee " . $outfile;
  }
  else
  {
    $cmd = "cleartool mklabel -recurse -nc " . $ReleaseNum . " . > " . $outfile;
  }
  if( $CrProcess::DEBUG & hex(1) )
  {
    print $cmd . "\n";
  }

  unless( $CrProcess::DEBUG & hex(8) )
  {
    print "Applying label \"" . $ReleaseNum . "\" to VOB: " . $vob . "\n\n";
    # apply the label to the VOB
    system $cmd;
    open( MKLABEL, $outfile ) or die "Cannot open file $outfile: $!\n";
    open( LABEL_REPORT, ">>$LabelReport" ) or die "Cannot open file $LabelReport: $!\n";

    print LABEL_REPORT `pwd`;
    foreach my $line ( <MKLABEL> )
    {
      if( $line =~ /cleartool: Error:/ )
      {
        print LABEL_REPORT $line;
        unless( $line =~ /lost\+found/ )
        {
          print $line;
          $returnVal = 1;
        }
      }

      # print summary
      if( $line =~ /versions.$/ )
      {
        print LABEL_REPORT $line;
      }
      if( $line =~ /applied$/ )
      {
        print LABEL_REPORT $line;
      }
      if( $line =~ /moved$/ )
      {
        print LABEL_REPORT $line;
      }
      if( $line =~ /place$/ )
      {
        print LABEL_REPORT $line;
      }
      if( $line =~ /failed$/ )
      {
        print LABEL_REPORT $line;
      }
    }
    print LABEL_REPORT "\n\n";
    close( LABEL_REPORT );
    close( MKLABEL );
  }
  return $returnVal;
}


###############################################################################
# createMainlineLabels -- Releases may not always change the main line but some
#              VOBs are main line development only.  Set the merge config spec
#              to just /main/LATEST and apply the label.
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub createMainlineLabels
{
  my $returnVal = 0;

  $returnVal = &labelOneVob( $CrProcess::DOCS_VOB );
  unless( $returnVal )
  {
    $returnVal = &labelOneVob( $CrProcess::SCM_VOB );
  }

  return $returnVal;
}


###############################################################################
# setLabelViewConfigSpec -- set the config spec of the label view to be
#                           appropriate for a label stage operation
#                    
#
# parameters
#   $operation -- string containing the name of the config spec to set to the
#                 label view
#
# returns
#   NONE
###############################################################################
sub setLabelViewConfigSpec
{
  my ( $operation ) = @_;

  open( CS, ">$CS" ) or die "Cannot open config spec file $CS: $!\n";
  if( $operation eq "merge" )
  {
    my @configSpec = split( "\n", $MergeViewConfigSpec );
    foreach my $line ( @configSpec )
    {
      next if( $line =~ /-none/ );

      print CS $line . "\n";
    }
  }
  elsif( $operation eq "main" )
  {
    print CONFIGSPEC "element * /main/LATEST\n";
  }
  elsif( $operation eq "release" )
  {
    # set the label view's config spec to just the release label
    print CS "element * " . $ReleaseNum . "\n";
  }
  else
  {
    die "Unknown label configspec operation: $operation\n";
  }
  close CS;

  # set the config spec
  unless( $CrProcess::DEBUG & hex(8) )
  {
    system "cleartool", "setcs", $CS;
    unlink $CS;
  }

  if( $CrProcess::DEBUG & hex(1) )
  {
    system "cleartool", "catcs";
  }
}


###############################################################################
# verifyLabel -- Create a view with the config spec set to the release label.
#                Compare this view against the conflicts view.
#
#                NOTE: The config spec for the conflicts view gives the parent
#                branch rule greater precedence than the baseline rule.  This
#                will result in the newly updated version file appearing in the
#                conflicts view after checkin.  The version file must be tested
#                separately.
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub verifyLabel
{
  # Get the name of the conflicts view
  $ConflictsView = &CrProcess::createView( $ReleaseNum,
                                           $CrProcess::CONFLICTS,
                                           $CrProcess::VIEW_USE_EXISTING ); 

  # check to see which VOBs have had changes applied
  my @changedVobs = ();
  &CrProcess::findChangedVobs( $ReleaseNum, \@changedVobs );

  # Only execute comparison on VOBs whose contents have changed in this release
  foreach my $vob ( @changedVobs )
  {
    chdir "../$vob";

    if( $CrProcess::DEBUG & hex(1) )
    {
      system "pwd";
    }

    my $conflictsVob = "M:/" . $ConflictsView . "/" . $vob;
    my $labelVob = "M:/" . $LabelView . "/" . $vob;

    if( $CrProcess::DEBUG & hex(1) )
    {
      print "\$conflictsVob = " . $conflictsVob . "\n";
      print "\$labelVob = " . $labelVob . "\n";
    }

    unless( $CrProcess::DEBUG & hex(8) )
    {
      # compare the contents of the label in this directory against the
      # conflicts config spec
      &CrProcess::fileCompare( $conflictsVob,
                               $labelVob,
                               $LabelReport );
    }
  }

  # Compare the version file against its predecessor
  open( LABEL_REPORT, ">>$LabelReport" ) or die "Cannot open file $LabelReport: $!\n";
  print LABEL_REPORT "Differences between current version file and predecessor:\n";
  close( LABEL_REPORT );

  my $cmd = "cleartool diff -dif -pred " . $LabelVobRoot;
  $cmd .= $CrProcess::VERSION_FILE . " >> " . $LabelReport;
  if( $CrProcess::DEBUG & hex(1) )
  {
    print $cmd . "\n";
  }
  system $cmd;
}


###############################################################################
# sendLabelEmail -- mail the label report to the build engineer
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub sendLabelEmail
{
  my $subject = "";

  print "\nSending " . $CrProcess::LABEL . " email:\n\n";

  my $subject = $ReleaseNum . " " . $CrProcess::LABEL . " ";
  if( $LabelReport =~ /(.*?)_$CrProcess::LABEL(\d+)/ )
  {
      $subject .= $2 . "\n\n";
  }

  &CrProcess::sendEmail( $LabelReport,
                         {},
                         $subject );
}

