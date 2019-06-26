#!C:/PROGRA~1/Rational/ClearCase/bin/ccperl.exe

###############################################################################
# 07_release_notes.pl -- Generate release notes from data generated during the
#                        release process.
###############################################################################

use strict;

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

# GetOpt variables
#   q = quiet (do not email results)
#   t = target release
our( $opt_q, $opt_t );

# operating variables
my $ReleaseNum = "";
my $NoEmail = "";

my $ReleaseNotes = "";

###############################################################################
# Main Program Body
#
{
  getopts( "qt:" );

  $ReleaseNum = $opt_t;
  &usage() unless $ReleaseNum;
  $NoEmail = $opt_q;

  $ReleaseNotes = &CrProcess::createReportFile( $ReleaseNum,
                                                $CrProcess::RELEASE_NOTES );

  # only one release file will exist so delete the old one if present
  if( -e $ReleaseNotes )
  {
    system "rm", "-rf", $ReleaseNotes;
  }

  # report the config spec
  &reportConfigSpec();

  # get CR details from ClearQuest
  &getCrDetails();

  # report the configurations built
  &reportBuildConfigs();

  &sendReleaseNotesEmail() unless $NoEmail;
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
  print "Usage:  07_release_notes.pl -t <target_release> [-q]\n";
  print "Where:\n";
  print "\ttarget_release = ClearQuest target release string\n";
  print "\t-q = do not send email notification\n";

  exit( -1 );
}


###############################################################################
# reportConfigSpec -- get the config spec of the conflicts view and add to
#                     release notes file
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub reportConfigSpec
{
  # Get the name of the conflicts view
  my $ConflictsView = &CrProcess::createView( $ReleaseNum,
                                              $CrProcess::CONFLICTS,
                                              $CrProcess::VIEW_USE_EXISTING ); 

  # change to the conflicts view
  if( $ConflictsView )
  {
    chdir "M:\\" . $ConflictsView . "\\" . $CrProcess::VOB;
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

  open( OUTFILE, ">>$ReleaseNotes" ) or die "Cannot open file $ReleaseNotes: $!\n";
  print OUTFILE "=" x79 . "\n";
  print OUTFILE "Release config spec\n";
  print OUTFILE "=" x79 . "\n";
  print OUTFILE `cleartool catcs`;
  print OUTFILE "\n";
  close OUTFILE;
}


###############################################################################
# getCrDetails -- Query ClearQuest for the CRs included in this release and add
#                 the field data to the release notes file.
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub getCrDetails
{
  my %CRs = ();

  my $printSeparator = 0;

  # this function gets more detail from ClearQuest--previous queries just get
  # the database ID
  &CrProcess::getCqRecordDetails( $ReleaseNum, \%CRs );

  open( OUTFILE, ">>$ReleaseNotes" ) or die "Cannot open file $ReleaseNotes: $!\n";
  print OUTFILE "=" x79 . "\n";
  print OUTFILE "CRs resolved in this release\n";
  print OUTFILE "=" x79 . "\n";
  foreach my $cr ( sort keys %CRs )
  {
    if( $printSeparator )
    {
      print OUTFILE "=" x79 . "\n\n";
    }
    print OUTFILE "ID = " . $cr . "\n\n";
    print OUTFILE "Assigned User:\n";
    print OUTFILE $CRs{$cr}->{$CrProcess::CQ_ASSIGNED_USER_FIELD} . "\n\n";
    print OUTFILE "Subsystem:\n";
    print OUTFILE $CRs{$cr}->{$CrProcess::CQ_SUBSYSTEM_FIELD} . "\n\n";
    print OUTFILE "Headline:\n";
    print OUTFILE $CRs{$cr}->{$CrProcess::CQ_HEADLINE_FIELD} . "\n\n";
    print OUTFILE "Description:\n";
    print OUTFILE $CRs{$cr}->{$CrProcess::CQ_DESCRIPTION_FIELD} . "\n\n";
    print OUTFILE "Unit Test Details:\n";
    print OUTFILE $CRs{$cr}->{$CrProcess::CQ_UNIT_TEST_DETAILS_FIELD} . "\n\n";
    print OUTFILE "Fix Details:\n";
    print OUTFILE $CRs{$cr}->{$CrProcess::CQ_FIX_DETAILS_FIELD} . "\n\n";
    print OUTFILE "Files Changed:\n";
    print OUTFILE $CRs{$cr}->{$CrProcess::CQ_FILES_CHANGED_FIELD} . "\n";

    $printSeparator = 1;
  }
  close OUTFILE;
}


###############################################################################
# reportBuildConfigs -- Get the latest merge build report from the network and
#                       copy that to the release notes.
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub reportBuildConfigs
{
  my $printLine = 1;

  my $buildReport = &CrProcess::createReportFile( $ReleaseNum,
                                                  $CrProcess::VERIFICATION,
                                                  "use_existing" );

  open( BUILD_REPORT, $buildReport ) or die "Cannot open $buildReport: $!\n";
  open( OUTFILE, ">>$ReleaseNotes" ) or die "Cannot open file $ReleaseNotes: $!\n";
  print OUTFILE "=" x79 . "\n";
  print OUTFILE "Configurations built for this release\n";
  print OUTFILE "=" x79 . "\n";
  foreach my $line ( <BUILD_REPORT> )
  {
    # skip config spec section
    if( $line =~ /config spec/ )
    {
      $printLine = 0;
    }

    if( $printLine )
    {
      print OUTFILE $line;
    }

    # look for label line
    if( $line =~ /element \* ([A-Z]+?)_/ )
    {
      $printLine = 1;
    }
  }
  close( OUTFILE );
  close( BUILD_REPORT );
}


###############################################################################
# sendReleaseNotesEmail -- mail the label report to the build engineer and CC
#                          the development team.
#
# parameters
#   NONE
#
# returns
#   NONE
###############################################################################
sub sendReleaseNotesEmail
{
  my $subject = "";
  my %recipientList = ();

  $recipientList{ $CrProcess::BUILD_ENG } = 1;

  print "\nSending " . $CrProcess::RELEASE_NOTES . " email:\n";

  my $subject = $ReleaseNum . " " . $CrProcess::RELEASE_NOTES . " ";
  if( $ReleaseNotes =~ /(.*?)_$CrProcess::RELEASE_NOTES(\d+)/ )
  {
      $subject = $subject . $2 . "\n";
  }

  &CrProcess::sendEmail( $ReleaseNotes,
                         \%recipientList,
                         $subject );
}

