#!C:/PROGRA~1/Rational/ClearCase/bin/ccperl.exe

###############################################################################
# 02_04_build.pl -- Queries ClearQuest for the list of  build configurations
#                   and executes builds for the appropriate stage of the
#                   release process.
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

my $MAKE_DIR = "\\Build\\groupsrc";
# subdirectory of the Viking project for debugging
my $SUBSYS_DIR = "\\DCI\\groupsrc";

my $BUILD_DIR = "";

#
# Globals
#

# GetOpt variables
#   l = use current view and config spec 
#   q = quiet (do not email results)
#   s = stage
#   t = target release
#   u = unit -- BD or GUI
our( $opt_l, $opt_q, $opt_s, $opt_t, $opt_u );

# operating variables
my $ReleaseNum = "";
my $ViewOption = "";
my $Stage = "";
my $NoEmail = "";
my $Local = "";
my $Unit = "";

my $BuildDir = "";
my $BuildReport = "";

my %RecipientList = ();

# get CR list to unlock branches if the build fails
my %CRs = ();

# database for identifying and separating requested build configurations
my %BuildConfigurations = ();

###############################################################################
# Main Program Body
#
{
  getopts( "lqs:t:u:" );

  $ReleaseNum = $opt_t;
  &usage() unless $ReleaseNum;
  $NoEmail = $opt_q;
  $Local = $opt_l;
  $Unit = $opt_u;

  if( $opt_s =~ /test/i )
  {
    $Stage = $CrProcess::TEST_BUILD;
    # test build should always be performed in a new view
    $ViewOption = $CrProcess::VIEW_FORCE_RECREATE;
  }
  elsif( $opt_s =~ /merge/i )
  {
    $Stage = $CrProcess::MERGE;
    # recreating merge view will undo the merge
    # If the build fails, the merge must be undone to allow the resulting
    # change to be brought into the release
    $ViewOption = $CrProcess::VIEW_USE_EXISTING;
  }
  else
  {
    &usage();
  }

  # get the name of the build view, either by echoing the name of the local
  # view or by creating a new view.
  my $buildView = "";
  if( $Local )
  {
    $buildView = `cleartool pwv -short`;
    chomp $buildView;
  }
  else
  {
    $buildView = &CrProcess::createView( $ReleaseNum,
                                         $Stage,
                                         $ViewOption );
  }

  # change our working directory to the build view only if the name of the view
  # was set in the previous step
  if( $buildView )
  {
    my $chDir = "M:\\" . $buildView . "\\" . $CrProcess::VOB;
    if( $CrProcess::DEBUG & hex(20) )
    {
      $BUILD_DIR = $SUBSYS_DIR;
    }
    else
    {
      $BUILD_DIR = $MAKE_DIR;
    }

    chdir $chDir or die "Cannot change to directory $chDir: $!\n";

    # output debug information only if the correct bit is set.  See the
    # CrProcess.pm module for bitfield values
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
    die "Cannot access build view.\n";
  }

  # If this is a Merge Verification build, we are now using all of the
  # ClearCase resources that were created in the Merge step of the release
  # process.  Change the $Stage variable to use the proper network resources
  # for build storage and reports
  if( $Stage eq $CrProcess::MERGE )
  {
    $Stage = $CrProcess::VERIFICATION;
  }

  # Create next iteration of build report
  $BuildReport = &CrProcess::createReportFile( $ReleaseNum, $Stage );
  # get the network directory from the build report path
  $BuildDir = $BuildReport;
  $BuildDir =~ s/(.*\\).*/$1/;

  if( $CrProcess::DEBUG & hex(1) )
  {
    print "\$BuildDir = " . $BuildDir . "\n";
    print "\$BuildReport = " . $BuildReport . "\n";
  }

  # don't change the config spec in a local build
  unless( $Local )
  {
    &createConfigSpec( $Stage );
  }

  # Get all CRs for this release and populate the hash with the requested
  # configurations
  &CrProcess::getConfigsFromCQ( $ReleaseNum, \%BuildConfigurations, $Unit );

  # remove the directories created during the previous script run
  &cleanNetworkDirectories();

  # execute builds for each configuration in the hash
  &getBuildInstructions();

  &sendBuildEmail() unless $NoEmail;

  # Dump the contents of the build configurations hash to a text file
  if( $CrProcess::DEBUG & hex(10) )
  {
    open DATADUMP, ">$FindBin::Bin/02_04_dumpfile.txt" or die "Cannot open dump file: $!\n";
    print DATADUMP "Build configurations:\n\n";
    print DATADUMP Dumper( \%BuildConfigurations );
    print DATADUMP "\n";
    print DATADUMP "Change Requests:\n\n";
    print DATADUMP Dumper( \%CRs );
    close DATADUMP;
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
  print "Usage:  02_04_build.pl -t <target_release> -s <stage> [-l] [-q]";
  print " [-u <unit>]\n";
  print "Where:\n";
  print "\ttarget_release = ClearQuest target release string\n";
  print "\tstage = Release stage\n";
  print "\t\ttest = pre-merge test build\n";
  print "\t\tmerge = Engineering verification build (post-merge)\n";
  print "\t-l = execute the build in the current view\n";  
  print "\t-q = do not send email notification\n";
  print "\tunit = build only configurations appropriate for a specific unit\n";
  print "\t\tbd = build configurations for BD unit release\n";
  print "\t\tgui = build configurations for GUI unit release\n";

  exit( -1 );
}


###############################################################################
# createConfigSpec -- Read the config spec from the conflicts view and apply
#                     that configspec to the test build view
#
# parameters
#   $releaseStage -- string identifying whether this is a test or merge build
#
# returns
#   NONE
###############################################################################
sub createConfigSpec
{
  my ( $releaseStage ) = @_;

  my $outfile = "";

  # get the name of the current conflicts view
  my $conflictsView = &CrProcess::createView( $ReleaseNum,
                                              $CrProcess::CONFLICTS,
                                              $CrProcess::VIEW_USE_EXISTING ); 

  # Only set the config spec in a pre-merge build.  Otherwise report the branch
  # list config spec (conflicts) to the build report.
  if( $releaseStage eq $CrProcess::TEST_BUILD )
  {
    $outfile = $CS;
  }
  else
  {
    $outfile = $BuildReport;
  }

  # Execute the ClearCase command to retrieve the config spec
  my $cmd = "cleartool catcs -tag " . $conflictsView;
  if( $CrProcess::DEBUG & hex(1) )
  {
    print "\$cmd = " . $cmd . "\n";
  }
  open( CONFLICTS_CS, "$cmd |" );
  open( OUTFILE, ">$outfile" ) or die "Cannot open output file $outfile: $!\n";
  # output each line of the config spec as they're read from the conflicts view
  foreach my $line ( <CONFLICTS_CS> )
  {
    if( $CrProcess::DEBUG & hex(1) )
    {
      print $line;
    }
    print OUTFILE $line;
  }
  close OUTFILE;
  close CONFLICTS_CS;

  # set the config spec of the test build view
  if( $releaseStage eq $CrProcess::TEST_BUILD )
  {
    system "cleartool", "setcs", $CS;
    unlink $CS;
  }
}


###############################################################################
# cleanNetworkDirectories -- Delete old network storage locations
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub cleanNetworkDirectories
{

  print "Cleaning network build directories...\n";

  # get the build configurations from the hash
  # get requested builds first
  my @nodes = ( "requested", "all" );

  foreach my $node ( @nodes )
  {
    &cleanOneDirectory( \%{$BuildConfigurations{$node}} );
  }
}


###############################################################################
# cleanOneDirectory -- Delete storage directory for current configuration and
#                      check for dependent configurations
#
# parameters
#   $hashRef -- Reference to a hash representing the current location on the
#               database structure.  This is not necessarily the root because
#               of recursive function calls.
#
# returns
#   NONE
###############################################################################
sub cleanOneDirectory
{
  my ( $hashRef ) = @_;

  foreach my $name ( keys %$hashRef )
  {
    my $destDir = "";
    my $result = "";

    $destDir = $BuildDir . $name;

    # remove the existing directory.
    if( -e $destDir )
    {
      my $cmd = "rm -rf " . $destDir;
      if( $CrProcess::DEBUG & hex(1) )
      {
        print "\$cmd = " . $cmd . "\n";
      }
      print "Removing existing directory for configuration " . $name . "\n";
      $result = system $cmd;
      die "Cannot remove directory for configuration $name: $!\n" if $result;
    }
    else
    {
      if( $CrProcess::DEBUG & hex(1) )
      {
        print "No existing build directory for " . $name . "\n";
      }
    }

    &cleanOneDirectory( \%{$$hashRef{$name}->{dependency}} );
  }
}


###############################################################################
# getBuildInstructions -- Traverse the hash and build each configuration from
#                         the prerequisites down, starting with the "requested"
#                         node.
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub getBuildInstructions
{
  # get the build configurations from the hash
  # get requested builds first
  my @nodes = ( "requested", "all" );

  foreach my $node ( @nodes )
  {
    &executeBuilds( \%{$BuildConfigurations{$node}} );
  }
}


###############################################################################
# executeBuilds -- retrieve the configuration data from the hash and pass to the
#                  subroutine to execute the individual build
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub executeBuilds
{
  my ( $hashRef ) = @_;

  my $error = 0;

  foreach my $name ( keys %$hashRef )
  {
    # certain library configurations have no clean target
    if( $$hashRef{$name}->{$CrProcess::CQ_BUILD_CFG_CLEAN_TARGET_FIELD} )
    {
      $error = &executeOneBuild( $name,
                                 $$hashRef{$name}->{$CrProcess::CQ_BUILD_CFG_MAKEFILE_PATH_FIELD},
                                 $$hashRef{$name}->{$CrProcess::CQ_BUILD_CFG_CLEAN_TARGET_FIELD},
                                 $$hashRef{$name}->{$CrProcess::CQ_BUILD_CFG_BUILD_FLAGS_FIELD},
                                 \%{$$hashRef{$name}->{owners}} );
    }

    $error = &executeOneBuild( $name,
                               $$hashRef{$name}->{$CrProcess::CQ_BUILD_CFG_MAKEFILE_PATH_FIELD},
                               $$hashRef{$name}->{$CrProcess::CQ_BUILD_CFG_BUILD_TARGET_FIELD},
                               $$hashRef{$name}->{$CrProcess::CQ_BUILD_CFG_BUILD_FLAGS_FIELD},
                               \%{$$hashRef{$name}->{owners}} );

    if( $error )
    {
      &unlockBranches();
      $error = 0;
    }

    &executeBuilds( \%{$$hashRef{$name}->{dependency}} );
  }
}


###############################################################################
# executeOneBuild -- Set up the build command and launch the build.  Direct 
#                    output to a logfile.  
#
# parameters
#   $name -- friendly name to identify the build and options
#   $makefilePath -- view-relative path to the directory containing the makefile
#   $target -- build target, currently either bd or gui
#   $buildOptions -- additional command-line options to customize the build
#   $ownersRef -- reference to a hash containing the names of users to be
#                 notified of the build results
#
# returns
#   NONE
###############################################################################
sub executeOneBuild
{
  my ( $name, $makefilePath, $target, $buildOptions, $ownersRef ) = @_;
  my $error = 0;
  my $buildResult = "";
  my $configRebuild = 0;

  my $destDir = $BuildDir . $name;

  if( $CrProcess::DEBUG & hex(1) )
  {
    print "\n";
    print "\$name = " . $name . "\n";
    print "\$makefilePath = " . $makefilePath . "\n";
    print "\$target = " . $target . "\n";
    print "\$buildOptions = " . $buildOptions . "\n";
    print "\$destDir = " . $destDir . "\n";
  }

  # Don't create the directory if it already exists
  unless( -e $destDir )
  {
    my $cmd = "mkdir " . $destDir;
    if( $CrProcess::DEBUG & hex(1) )
    {
      print "\$cmd = " . $cmd . "\n";
    }
    my $result = system $cmd;
    die "Cannot create directory for configuration $name: $!\n" if $result;
  }

  # create the log file in the correct build directory
  my $logfile = $destDir . "\\" . $name;
  if( $target =~ /clean/ )
  {
    $logfile .= "_clean";
  }
  $logfile .= ".log";
  # Don't overwrite an existing logfile
  if( -e $logfile )
  {
    print "Log file " . $logfile . " already exists.\n";
    $logfile = "/dev/null";
    $configRebuild = 1;
  }

  # add the comand issued to the build report
  open( LOGFILE, ">$logfile" ) or die "Cannot open file $logfile: $!\n";
  print LOGFILE "Build command executed:  ";
  print LOGFILE "make " . $target . " " . $buildOptions . "\n\n";
  close LOGFILE;

  # make sure the makefile exists before changing to the directory
  if( -e "../$makefilePath" )
  {
    # navigate to the makefile directory
    chdir "../$makefilePath";
    if( $CrProcess::DEBUG & hex(1) )
    {
      print "Before build: ";
      system "pwd";
    }

    # execute the build
    my $cmd = "make $target $buildOptions 2>&1 | tee -a $logfile";
    if( $CrProcess::DEBUG & hex(1) )
    {
      print "\$cmd = " . $cmd . "\n";
      print "\$logfile = " . $logfile . "\n";
    }

    # ...unless the debug is set to not to
    if( $CrProcess::DEBUG & hex(8) )
    {
      unless( $configRebuild )
      {
        system "touch $logfile";
      }
    }
    else
    {
      system $cmd;

      # script output will contain unix line endings.  Convert them to DOS.
      system "unix2dos", $logfile;
    }

    # return to the top level directory
    my @pathDepth = split( "/", $makefilePath );
    for( 1..$#pathDepth )
    {
      chdir "..";
    }

    if( $CrProcess::DEBUG & hex(1) )
    {
      print "After build: ";
      system "pwd";
    }

    # Open the build output file and scan for error messages.  Toggle the
    # "error" flag if the specified error messages are present.  This error
    # check needs to be revisited when the makefile changes.
    open( LOGFILE, "$logfile" ) or die "Cannot open file $logfile: $!\n";
    foreach my $line ( <LOGFILE> )
    {
      # make: *** [gui] Error 2
      if( ($line =~ /make(.*?)\*\*\*(.*?)Error/) ||
          ($line =~ /make(.*?)\*\*\*(.*?)No rule to make target/) )
      {
        $error = 1;
      }
    }
    close LOGFILE;
  }
  else
  {
     open( LOGFILE, "$logfile" ) or die "Cannot open file $logfile: $!\n";
     print "Could not determine makefile path: " . $makefilePath . "\n";
     close LOGFILE;
  }

  if( $error )
  {
    my $subject = "Build failed for configuration " . $name . "\n\n";

    # send email to build manager
    $$ownersRef{$CrProcess::BUILD_ENG} = 1;
    &CrProcess::sendEmail( $logfile,
                           $ownersRef,
                           $subject,
                           "no_cc" );

    $buildResult = "FAIL\n";
  }
  else
  {
    my $subject = "Build completed for configuration " . $name . "\n\n";
    unless( ($target =~ /clean/) || ($configRebuild) )
    {
      # send email to build manager
      $$ownersRef{$CrProcess::BUILD_ENG} = 1;
      &CrProcess::sendEmail( $logfile,
                             $ownersRef,
                             $subject,
                             "no_cc" );
    }
    $buildResult = "SUCCESS\n";
  }

  # Don't report duplicate pre-requisite builds
  unless( $configRebuild )
  {
    # output the currently building configuration 
    open( BUILD_REPORT, ">>$BuildReport" )
    or die "Cannot open file $BuildReport: $!\n";
    print BUILD_REPORT "Name:     " . $name . "\n";
    print BUILD_REPORT "Makefile Path:   " . $makefilePath . "\n";
    print BUILD_REPORT "Target:   " . $target . "\n";
    print BUILD_REPORT "Options:  " . $buildOptions . "\n";
    print BUILD_REPORT "Status:   ";
    print BUILD_REPORT $buildResult;
    print BUILD_REPORT "Log File: " . $logfile . "\n";
    print BUILD_REPORT "\n";
    close BUILD_REPORT;
  }

  # don't copy local builds
  # don't copy builds for "clean" target
  if( ($Local) ||
      ($target =~ /clean/i) ||
      ($Stage eq $CrProcess::TEST_BUILD) )
  {
    # legal condition, do nothing
  }
  else
  {
    # don't copy the build if it already exists
    if( $configRebuild )
    {
      print "Build " . $name . " has already been copied to the network.\n";
    }
    else
    {
      # copy the build directory to the network
      &copyFiles( $name );
    }
  }
  return $error;
}


###############################################################################
# copyFiles -- Copy files from the local directory to the specified network
#              location
#
# parameters
#   $name -- name of the target being built
#
# returns
#   NONE
###############################################################################
sub copyFiles
{
  my ( $name ) = @_;

  my $destDir = $BuildDir . $name;
  my $result = "";

  # perform the copy operation
  my $cmd = "xcopy . $destDir /i /s /e /r /h /x /y";

  if( $CrProcess::DEBUG & hex(1) )
  {
    print "\$cmd = " . $cmd . "\n";
  }

  unless( $CrProcess::DEBUG & hex(8) )
  {
    $result = system $cmd;
  }

  if( $result )
  {
    open( BUILD_REPORT, ">>$BuildReport" )
    or die "Cannot open file $BuildReport: $!\n";
    print BUILD_REPORT "xcopy operation failed for target " . $name . "\n";
    print BUILD_REPORT "\n";
    close BUILD_REPORT;
  }
}


###############################################################################
# unlockBranches -- Get the list of branches for this release and unlock them
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub unlockBranches
{
  print "\nUnlocking config spec:\n\n";

  &CrProcess::processCrList( $CrProcess::CONFLICTS,
                             $ReleaseNum,
                             \%CRs,
                             [] );

  &CrProcess::findBranches( \%CRs );

  # check to see which VOBs have had changes applied
  my @changedVobs = ();
  &CrProcess::findChangedVobs( $ReleaseNum, \@changedVobs );

  # Only process the VOBs whose contents were modified
  foreach my $vob ( @changedVobs )
  {
    chdir "../$vob";

    if( $CrProcess::DEBUG & hex(1) )
    {
      system "pwd";
    }

    # There may be multiple branches for each CR.  Walk through the database
    # and unlock all branches for all CRs.
    foreach my $cr ( sort keys %CRs )
    {
      # get each branch for the CR
      foreach my $branch ( sort keys %{$CRs{$cr}->{branches}} )
      {
        # check whether branch exists in this VOB
        my $descriptionCmd = "cleartool describe -short brtype:";
        $descriptionCmd .= $branch . " 2>&1";

        my $result = `$descriptionCmd`;
        next if( $result =~ /error/i );

        print "Unlocking branch " . $branch . "\n";

        if( ${$CRs{$cr}->{branches}{$branch}->{is_locked}} )
        {
          &CrProcess::lockBranch( $CrProcess::UNLOCK, $branch );
        }
        else
        {
          print "Branch " . $branch . " is already unlocked.\n";
        }
      } # end check branches
    } # end check change requests
  } # end check all VOBs
}


###############################################################################
# sendBuildEmail -- Send build summary to the build engineer and CC: developers
#                   if this is a merge build
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub sendBuildEmail
{
  my $subject = "";

  print "\nSending " . $Stage . " email:\n\n";

  my $subject = $ReleaseNum . " " . $Stage . " ";
  if( $BuildReport =~ /(.*?)_$Stage(\d+)/ )
  {
    $subject .= $2 . "\n\n";
  }

  # only send the build results email to the development team if this is a
  # post-merge build 
  if( $Stage eq $CrProcess::VERIFICATION )
  {
    # Adding the current user to the recipient list will result in the team
    # being cc'ed on the mailing.
    $RecipientList{ $CrProcess::BUILD_ENG } = 1;

    &CrProcess::sendEmail( $BuildReport,
                           \%RecipientList,
                           $subject );
  }
  else
  {
    &CrProcess::sendEmail( $BuildReport,
                           {},
                           $subject );
  }
}


