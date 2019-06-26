#!C:/PROGRA~1/Rational/ClearCase/bin/ccperl.exe

###############################################################################
# 06_obsolete.pl -- Query ClearQuest for CRs contained in this release and then
#                   find all branches for those CRs in ClearCase.  Change each
#                   existing branch to an obsolete branch name (*.obs) and lock
#                   and obsolete the new instance.
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

#
# Globals
#
my %CRs = ();

# GetOpt variables
#   q = quiet (do not email results)
#   t = target release
our( $opt_q, $opt_t );

# operating variables
my $ReleaseNum = "";
my $NoEmail = "";

my $ObsoleteReport = "";
my $ConflictsView = "";
my $ConflictsVobRoot = "";

###############################################################################
# Main Program Body
#
{
  getopts( "qt:" );

  $ReleaseNum = $opt_t;
  &usage() unless $ReleaseNum;
  $NoEmail = $opt_q;

  # do not recreate the Conflicts view
  $ConflictsView = &CrProcess::createView( $ReleaseNum,
                                           $CrProcess::CONFLICTS,
                                           $CrProcess::VIEW_USE_EXISTING ); 

  if( $ConflictsView )
  {
    $ConflictsVobRoot = "M:\\" . $ConflictsView . "\\" . $CrProcess::VOB;

    chdir $ConflictsVobRoot;
    if( $CrProcess::DEBUG & hex(1) )
    {
      print "Working Directory = ";
      system "pwd";
      print "Working View = ";
      system "cleartool pwv -short";
    }
  }

  # Create next iteration of build report
  $ObsoleteReport = &CrProcess::createReportFile( $ReleaseNum,
                                                  $CrProcess::OBSOLETE );

  # Get the list of CRs from ClearQuest
  &CrProcess::processCrList( $CrProcess::CONFLICTS,
                             $ReleaseNum,
                             \%CRs,
                             () );

  # find ClearCase branches for each CR
  &CrProcess::findBranches( \%CRs );

  # query elements for each branch
  &CrProcess::findElements( \%CRs );

  # separate ClearCase and ClearQuest operations for testing purposes
  unless( $CrProcess::DEBUG & hex(8) )
  {
    &CrProcess::processCrList( $CrProcess::OBSOLETE,
                               $ReleaseNum,
                               \%CRs,
                               () );
  }

  &obsoleteBranches();

  if( $CrProcess::DEBUG & hex(10) )
  {
    open DATADUMP, ">$FindBin::Bin/06_dumpfile.txt" or die "Cannot open dump file: $!\n";
    print DATADUMP Dumper( \%CRs );
    close DATADUMP;
  }

  # update ClearQuest Release records to set active_test and active_target
  # values
  &CrProcess::updateReleaseRecords( $ReleaseNum );

  &sendObsoleteEmail() unless $NoEmail;
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
  print "Usage:  06_obsolete.pl -t <target_release> [-q]\n";
  print "Where:\n";
  print "\ttarget_release = ClearQuest target release string\n";
  print "\t-q = do not send email notification\n";

  exit( -1 );
}


###############################################################################
# obsoleteBranches -- Traverse the CR hash and identify elements with branches
#                     to be obsoleted.
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub obsoleteBranches
{
  my @elements = ();

  # get CR list
  foreach my $cr ( sort keys %CRs )
  {
    # get branches for each CR
    foreach my $branch ( sort keys %{$CRs{$cr}->{branches}} )
    {
      next if( $branch =~ /.obs$/ );

      # get the list of elements from the branch
      foreach my $element ( @{$CRs{$cr}->{branches}{$branch}->{elements}} )
      {
        push( @elements, $element );
      } # iterate through elements

      # obsolete each instance of the branch.  Reverse-sort the array so that
      # directories are obsoleted last.  This prevents an obsolete directory
      # from hiding the directory contents
      foreach my $element ( sort {$b cmp $a} @elements )
      {
        &obsoleteOneBranch( $element, $branch );
      }

      @elements = ();
    } # iterate through branches
  } # iterate through CRs
}


###############################################################################
# obsoleteOneBranch -- Change the branch of an element to an obsoleted branch
#
# parameters
#   $element -- path to the element which contains the branch to be obsoleted
#   $branch -- branch type to obsolete
#
# returns
#   NONE
###############################################################################
sub obsoleteOneBranch
{
  my ( $element, $branch ) = @_;

  if( $CrProcess::DEBUG & hex(1) )
  {
    print "\$element = " . $element . "\n";
    print "\$branch = " . $branch . "\n";
  }

  # we can't be sure which VOB we'll be in when we execute this script.
  my $vob = "";
  if( $element =~ /([A-Z_]+?)\\/ )
  {
    $vob = $1;
    chdir "../$vob";
  }

  # check for correct branch and element types
  my $result = &CrProcess::checkBranch( $element, $branch, $ObsoleteReport );

  unless( ($result) || ($CrProcess::DEBUG & hex(8)) )
  {
    print "Obsoleting branch:\n\t " . $branch . " on element:\n\t ";
    print $element . "\n";

    open( OBSOLETE_REPORT, ">>$ObsoleteReport" )
    or die "Cannot open report file $ObsoleteReport: $!\n";
    print OBSOLETE_REPORT "Obsoleting branch:\n\t " . $branch . " on ";
    print OBSOLETE_REPORT "element:\n\t " . $element . "\n";
    close( OBSOLETE_REPORT );

    # unlock branches
    &CrProcess::lockBranch( $CrProcess::UNLOCK, $branch );
    &CrProcess::lockBranch( $CrProcess::UNLOCK, $branch . ".obs" );

    # change element's branch type from "branch" to "branch.obs"
    &CrProcess::changeBranch( $element, $branch );

    # lock branches
    &CrProcess::lockBranch( $CrProcess::LOCK, $branch );
    &CrProcess::lockBranch( $CrProcess::LOCK, $branch . ".obs" );
  }
}


###############################################################################
# sendObsoleteEmail -- mail the obsolete report to the build engineer
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub sendObsoleteEmail
{
  my $subject = "";

  print "\nSending " . $CrProcess::OBSOLETE . " email:\n\n";

  my $subject = $ReleaseNum . " " . $CrProcess::OBSOLETE . " ";
  if( $ObsoleteReport =~ /(.*?)_$CrProcess::OBSOLETE(\d+)/ )
  {
      $subject .= $2 . "\n\n";
  }

  &CrProcess::sendEmail( $ObsoleteReport,
                         {},
                         $subject );
}

