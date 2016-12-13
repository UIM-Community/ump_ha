# use dependencies
use strict;
use warnings;
use lib "D:/apps/Nimsoft/perllib";
use lib "D:/apps/Nimsoft/Perl64/lib/Win32API";
use Data::Dumper;
use Nimbus::API;
use Nimbus::CFG;
use Nimbus::PDS;
use perluim::log;
use perluim::main;
use perluim::utils;
use perluim::file;

#
# Declare default script variables & declare log class.
#
my $time = time();
my $version = "1.0";
my ($Console,$SDK,$Execution_Date,$Final_directory);
$Execution_Date = perluim::utils::getDate();
$Console = new perluim::log('ump_management.log',6,500000,'no');

# Handle critical errors & signals!
$SIG{__DIE__} = \&trap_die;
$SIG{INT} = \&breakApplication;

# Start logging
$Console->print('---------------------------------------',5);
$Console->print('ump_management started at '.localtime(),5);
$Console->print("Version $version",5);
$Console->print('---------------------------------------',5);

#
# Open and append configuration variables
#
my $CFG                 = Nimbus::CFG->new("ump_management.cfg");
my $Domain              = $CFG->{"setup"}->{"domain"} || undef;
my $Cache_delay         = $CFG->{"setup"}->{"output_cache_time"} || 432000;
my $Audit               = $CFG->{"setup"}->{"audit"} || 0;
my $Output_directory    = $CFG->{"setup"}->{"output_directory"} || "output";
my $Login               = $CFG->{"setup"}->{"nim_login"} || undef;
my $Password            = $CFG->{"setup"}->{"nim_password"} || undef;
my @ump_probes          = split(",",$CFG->{"setup"}->{"ump_probes"});

#
# nimLogin if login and password are defined in the configuration!
#
nimLogin($Login,$Password) if defined($Login) && defined($Password);

#
# Declare framework, create / clean output directory.
# 
$SDK                = new perluim::main("$Domain");
$Final_directory    = "$Output_directory/$Execution_Date";
$SDK->createDirectory("$Output_directory/$Execution_Date");
$Console->cleanDirectory("$Output_directory",$Cache_delay);

#
# Main method to call for the script ! 
# main();
# executed at the bottom of this script.
# 
sub main {

    $Console->print("Retrieving current robot.");
    my ($RC,$robot) = $SDK->getLocalRobot();
    if($RC == NIME_OK) {
        $RC = $robot->getLocalInfo();

        if($RC == NIME_OK) {
            my $addr = "/".$robot->{hubdomain}."/".$robot->{hubname}."/".$robot->{hubrobotname}; # primary hub addr!
            $Console->print("Entering into UMP reconfiguration with addr => $addr");

            #
            # Checkup for all probes!
            #
            foreach my $probe (@ump_probes) {
                $Console->print('---------------------------------------',5);
                $Console->print("Start checkup of probe $probe",3);
                if(checkConfiguration($probe,$addr,$robot->{name}) eq "yes") {
                    if(not $Audit) {
                        my $RC_RS = $robot->probeDeactivate($probe);
                        if($RC_RS == NIME_OK) {
                            $robot->probeActivate($probe) if reconfigureProbe($probe,$addr,$robot->{name}) eq "yes";
                            next;
                        }
                        $Console->print("Failed to deactivate the probe.",1); 
                    }
                    else {
                        $Console->pritn("Abort, Audit mode is on.");
                    }
                }
                else {
                    $Console->print("Skip reconfiguration OK..., nothing to do.",3);
                }
            }
        }
        else {
            $Console->print("Failed to execute gethub() callback!",0);
        }

    }
    else {
        $Console->print("Failed to get hub addr informations",0);
    }

}

#
# reconfigureProbe (probeName,hubaddr,robotname)
# this function will reconfigure the probe configuration ! 
# used in main() method.
#
sub reconfigureProbe {
	my $reconfigure_probe = "no";
	my ($probeName,$hubaddr,$robotname) = @_;

	$Console->print("reconfigureProbe: Entering",3);

	foreach my $probe (@ump_probes) {
		foreach my $section ($CFG->getSections($CFG->{"probes"}->{"$probe"})) {

			$Console->print("reconfigureProbe: will modify conf of $probe",2);
			foreach my $key ($CFG->getKeys($CFG->{"probes"}->{"$probe"}->{"$section"})) {

				my $val = $hubaddr."/".$CFG->{"probes"}->{"$probe"}->{"$section"}->{"$key"};
				$Console->print("reconfigureProbe: $probe : $section : $key -> $val",2);

				my $PDS = pdsCreate();
				pdsPut_PCH($PDS,"name","$probe");
				pdsPut_PCH($PDS,"section","$section");
				pdsPut_PCH($PDS,"key","$key");
				pdsPut_PCH($PDS,"value","$val");
				my ($RC, $RES) = nimRequest("$robotname",48000, "probe_config_set", $PDS);
				pdsDelete($PDS);
				if( $RC == NIME_OK ) {
                    $Console->print("reconfigureProbe : ...OK",2);
                    $reconfigure_probe = "yes";
				}
				else {
					$Console->print("reconfigureProbe: Unable to submit probe_config_set command on probe $probe, section $section, key $key",0);
				}
			}

		}
	}

	$Console->print("Reconfigure_UMP: Leaving with reconfigureProbe equal => $reconfigure_probe ",3);
	return $reconfigure_probe;
}

#
# checkConfiguration (probeName,hubaddr,robotname)
# this function will check that all keys are conformed to the expected value we want.
# used in main() method.
#
sub checkConfiguration {
	my ($probeName,$hubaddr,$robotname) = @_;
    my $reconfigure_ump = "no";

	$Console->print("checkConfiguration - Entering");
	CheckUMP: foreach my $probe (@ump_probes) {
        next if $probe ne $probeName; 
		foreach my $section ($CFG->getSections($CFG->{"probes"}->{"$probe"})) {
			foreach my $key ($CFG->getKeys($CFG->{"probes"}->{"$probe"}->{"$section"})) {
				my $expected_val = $hubaddr."/".$CFG->{"probes"}->{"$probe"}->{"$section"}->{"$key"};
				$Console->print("$section/$key should expect $expected_val");

				my $PDS = pdsCreate();
				pdsPut_PCH($PDS,"name","$probe");
				pdsPut_PCH($PDS,"var","/$section/$key");
				my ($RC, $PDS_Result) = nimRequest("$robotname",48000, "probe_config_get", $PDS);
				pdsDelete($PDS);

				if ( $RC == NIME_OK ) {
					my $current_val = (Nimbus::PDS->new($PDS_Result))->get("value");
					if ($current_val ne $expected_val) {
						$Console->print("Current key value is $current_val, but should be $expected_val",2);
						$reconfigure_ump = "yes";
						last CheckUMP;
					}
                    else {
                        $Console->print("Nothing to reconfigure... Next!");
                    }
				}
				else {
					$Console->print("Unable to submit probe_config_get command to $probe for reconfiguration of var=$section/$key",1);
				}
			}
		}
	}
	$Console->print("checkConfiguration - Leaving with reconfigure => $reconfigure_ump",3);
	return $reconfigure_ump;
}

#
# Die method
# trap_die($error_message)
# 
sub trap_die {
    my ($err) = @_;
	$Console->print("Program is exiting abnormally : $err",0);
    $| = 1; # Buffer I/O fix
    sleep(2);
    $Console->copyTo("output/$Execution_Date");
}

#
# When application is breaked with CTRL+C
#
sub breakApplication { 
    $Console->print("\n\n Application breaked with CTRL+C \n\n",0);
    $| = 1; # Buffer I/O fix
    sleep(2);
    $Console->copyTo("output/$Execution_Date");
    exit(1);
}

# Call the main method 
main();

$Console->finalTime($time);
$| = 1; # Buffer I/O fix
sleep(2);
$Console->copyTo($Final_directory);
$Console->close();
