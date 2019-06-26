#!C:/PROGRA~1/Rational/ClearCase/bin/ccperl.exe

###############################################################################
# 03_merge.pl -- Merge this release's element set from the development branches
#                to the Product branches.  Compare the merge to the conflicts
#                config spec and update the version file.
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
my $ViewOption = $CrProcess::VIEW_FORCE_RECREATE;

my $MergeReport = "";
my $ConflictsView = "";
my $ConflictsVobRoot = "";
my $MergeView = "";
my $MergeVobRoot = "";

###############################################################################
# Main Program Body
#
{
  getopts( "qt:" );

  $ReleaseNum = $opt_t;
  &usage() unless $ReleaseNum;
  $NoEmail = $opt_q;

  # re-create view each run unless not executing commands
  if( $CrProcess::DEBUG & hex(8) )
  {
    $ViewOption = $CrProcess::VIEW_USE_EXISTING;
  }

  $MergeView = &CrProcess::createView( $ReleaseNum,
                                       $CrProcess::MERGE,
                                       $ViewOption ); 

  if( $MergeView )
  {
    $MergeVobRoot = "M:\\" . $MergeView . "\\" . $CrProcess::VOB;

    # Get the config spec from the conflicts view
    $ConflictsView = $MergeView;
    $ConflictsView =~ s/$CrProcess::MERGE/conflicts/;
    $ConflictsVobRoot = "M:\\" . $ConflictsView . "\\" . $CrProcess::VOB;

    chdir $MergeVobRoot;
    if( $CrProcess::DEBUG & hex(1) )
    {
      print "Working Directory = ";
      system "pwd";
      print "Working View = ";
      system "cleartool pwv -short";
    }
  }

  &createConfigSpec();

  &performMerge();

  # Create next iteration of build report
  $MergeReport = &CrProcess::createReportFile( $ReleaseNum, $CrProcess::MERGE );

  print "Checking merge log for errors...\n\n";
  my $result = &checkMergeLog();

  # file compare does not check all VOBs
  unless( $result )
  {
    print "Comparing merge view against conflicts view...\n\n";
    &verifyMerge();

    print "Updating version file...\n\n";
    &updateVersionFile();
  }

  &sendMergeEmail() unless $NoEmail;
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
  print "Usage:  03_merge.pl -t <target_release> [-q]\n";
  print "Where:\n";
  print "\ttarget_release = ClearQuest target release string\n";
  print "\t-q = do not send email notification\n";

  exit( -1 );
}


###############################################################################
# createConfigSpec -- Set the merge view config spec.
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub createConfigSpec
{
  my $cmd = "cleartool catcs -tag " . $ConflictsView;
  open( CONFLICTS_CS, "$cmd |" );
  open( CS, ">$CS" ) or die "Cannot open config spec file $CS: $!\n";
  foreach my $line ( <CONFLICTS_CS> )
  {
    # do not print developer branches to the Merge Build config spec
    # developer branch
    next if( $line =~ /(([a-z\.\-]+)?)_(\d{$CrProcess::CR_NUM_LEN})\/LATEST/ );
    # release integration branch
    next if( $line =~ /intg/ );
    # blank lines
    next if( $line =~ /^\s+$/ );

    if( $CrProcess::DEBUG & hex(1) )
    {
      print $line;
    }
    print CS $line;
  }
  close CS;
  close CONFLICTS_CS;

  # set the config spec
  system "cleartool", "setcs", $CS;
  unlink $CS;
}


###############################################################################
# performMerge -- executes the cleartool findmerge command using this release's
#                 conflicts view as the source element for each element's
#                 merge.
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub performMerge
{
  my $ConflictsView = $MergeView;
  $ConflictsView =~ s/$CrProcess::MERGE/conflicts/;

  # check to see which VOBs have had changes applied
  my @changedVobs = ();
  &CrProcess::findChangedVobs( $ReleaseNum, \@changedVobs );

  # Merge each VOB independently
  foreach my $vob ( @changedVobs )
  {
    chdir "../$vob";

    if( $CrProcess::DEBUG & hex(1) )
    {
      system "pwd";
    }

    # from the current view (the merge view) execute the ClearCase command to
    # merge all branches in the conflicts view to the current release line as
    # defined in the config spec.
    my $cmd = "cleartool findmerge -all -nc -ftag " . $ConflictsView . " -merge";
    if( $CrProcess::DEBUG & hex(1) )
    {
      print $cmd . "\n";
    }

    unless( $CrProcess::DEBUG & hex(8) )
    {
      system $cmd;
    }
  }
}


###############################################################################
# checkMergeLog -- parse the merge log and check for elements that were
#                  identified as not merged.
#
# parameters
#   NONE
#
# returns
#   integer value, zero if all elements have been merged, nonzero if elements
#   were not merged.
###############################################################################
sub checkMergeLog
{
  my $returnVal = 0;

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

    # find the merge log
    opendir( VOB_ROOT, "." ) or die "Cannot open VOB Root directory: $!\n";
    my $fileName = "";
    while( $fileName = readdir(VOB_ROOT) )
    {
      chomp $fileName;
      # since the merge must only be performed in a clean view, take the first
      # findmerge file we encounter
      last if( $fileName =~ /findmerge.log/ );
    }
    closedir( VOB_ROOT );

    # Not all VOBs will be merged.  A findmerge.log file will be created for
    # each VOB that is merged so do not continue if the file does not exist.
    next unless( $fileName );

    if( $CrProcess::DEBUG & hex(1) )
    {
      print $fileName . "\n";
    }

    open( MERGE_REPORT, ">>$MergeReport" ) or die "Cannot open file $MergeReport: $!\n";
    open( FINDMERGE, $fileName ) or die "Cannot open file $fileName: $!\n";
    print MERGE_REPORT "Files not merged in VOB " . $vob . ":\n";
    foreach my $line ( <FINDMERGE> )
    {
      # successful merges will represented by the "#" character at the start of
      # the line
      next if( $line =~ /^\x23/ );

      if( $CrProcess::DEBUG & hex(1) )
      {
        print $line;
      }
      print MERGE_REPORT $line;

      $returnVal = 1;
    }
    close( FINDMERGE );
    print MERGE_REPORT "\n";
    close( MERGE_REPORT );
  }
  return $returnVal;
}


###############################################################################
# verifyMerge -- Compare the completed merge against the conflicts view
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub verifyMerge
{

  # check to see which VOBs have had changes applied
  my @changedVobs = ();
  &CrProcess::findChangedVobs( $ReleaseNum, \@changedVobs );

  # only perform operations on VOBs whose contents have changed as part of the
  # release
  foreach my $vob ( @changedVobs )
  {
    chdir "../$vob";

    # build the path to the current VOB in both the conflicts view and the
    # merge view
    my $conflictsVob = "M:/" . $ConflictsView . "/" . $vob;
    my $mergeVob = "M:/" . $MergeView . "/" . $vob;

    if( $CrProcess::DEBUG & hex(1) )
    {
      print "\$conflictsVob = " . $conflictsVob . "\n";
      print "\$mergeVob = " . $mergeVob . "\n";
    }

    # Compare the contents of the VOB path in the conflicts view against the
    # contents of the VOB path in the merge view
    &CrProcess::fileCompare( $conflictsVob,
                             $mergeVob,
                             $MergeReport );
  }
}


###############################################################################
# updateVersionFile -- check out the version file and update the version string
#                      with this release's version label.
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub updateVersionFile
{
  my $oldReleaseNum = "";
  my $versionFile = $MergeVobRoot . $CrProcess::VERSION_FILE;
  # check out version file
  my $cmd = "cleartool co -nc " . $versionFile;

  if( $CrProcess::DEBUG & hex(1) )
  {
    system "pwd";
    print $cmd . "\n";
  }

  unless( $CrProcess::DEBUG & hex(8) )
  {
    system $cmd;
  }

  # look for version string
  open( VERSION_FILE, $versionFile ) or die "Cannot open file $versionFile: $!\n";
  foreach my $line ( <VERSION_FILE> )
  {
    # "VIKING_1_0.0.0.6" or "FI_VIKING_GUI_0.0.0.10_1"
    if( $line =~ /\"(([A-Z_]+?)_((\d_)?)\d{1,2}(\.\d{1,2}){3}(.+)?)\"/ )
    {
        $oldReleaseNum = $1;
    }
  }
  close( VERSION_FILE );

  if( $CrProcess::DEBUG & hex(1) )
  {
    print "\$oldReleaseNum = " . $oldReleaseNum . "\n";
  }

  # replace with current version string
  {
    # temporarily set the currently running instance of Perl to allow in-line
    # editing.  
    local( $^I, @ARGV ) = ( '.contrib', $versionFile );
    while( <> )
    {
      $_ =~ s/$oldReleaseNum/$ReleaseNum/;
      print $_;
      close( ARGV ) if eof; 
    }
  }

  # compare the edited version file against the copy of the original (the
  # .contrib version)
  &CrProcess::fileCompare( $versionFile,
                           $versionFile . ".contrib",
                           $MergeReport );
}


###############################################################################
# sendMergeEmail -- send the merge results to the build engineer
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub sendMergeEmail
{
  my $subject = "";

  print "\nSending " . $CrProcess::MERGE . " email:\n\n";

  my $subject = $ReleaseNum . " " . $CrProcess::MERGE . " ";
  if( $MergeReport =~ /(.*?)_$CrProcess::MERGE(\d+)/ )
  {
      $subject .= $2 . "\n\n";
  }

  &CrProcess::sendEmail( $MergeReport,
                         {},
                         $subject );
}

