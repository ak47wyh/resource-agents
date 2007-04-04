#!/usr/bin/perl 

###############################################################################
###############################################################################
##
##  Copyright (C) 2006-2007 Red Hat, Inc.  All rights reserved.
##  
##  This copyrighted material is made available to anyone wishing to use,
##  modify, copy, or redistribute it subject to the terms and conditions
##  of the GNU General Public License v.2.
##
###############################################################################
###############################################################################

$|=1;

eval { $ssl_mod="Net::SSL" if require Net::SSL} || 
eval { $ssl_mod="Net::SSLeay::Handle" if require Net::SSLeay::Handle } || 
	die "Net::SSL.pm or Net::SSLeay::Handle.pm not found.\n".
	    "Please install the perl-Crypt-SSLeay package from RHN (http://rhn.redhat.com)\n".
	    "or Net::SSLeay from CPAN (http://www.cpan.org)\n";

use IO::Socket;
use Getopt::Std;

# WARNING!! Do not add code bewteen "#BEGIN_VERSION_GENERATION" and 
# "#END_VERSION_GENERATION"  It is generated by the Makefile

#BEGIN_VERSION_GENERATION
$FENCE_RELEASE_NAME="";
$REDHAT_COPYRIGHT="";
$BUILD_DATE="";
#END_VERSION_GENERATION

# Get the program name from $0 and strip directory names
$_=$0;
s/.*\///;
my $pname = $_;


################################################################################
sub usage 
{
	print "Usage:\n";
	print "\n";
	print "$pname [options]\n";
	print "\n";
	print "Options:\n";
	print "  -a <ip>          IP address or hostname of iLO card\n";
	print "  -h               usage\n";
	print "  -l <name>        Login name\n";
	print "  -o <string>      Action: reboot (default), off, on or status\n";
	print "  -p <string>      Login password\n";
	print "  -S <path>        Script to run to retrieve login password\n";
	print "  -q               quiet mode\n";
	print "  -V               version\n";
	print "  -v               verbose\n";
	exit 0;
}


sub fail
{
	($msg)=@_;
	print $msg unless defined $quiet;
	exit 1;
}


sub fail_usage
{
	($msg)=@_;
	print STDERR $msg if $msg;
	print STDERR "Please use '-h' for usage.\n";
	exit 1;
}


sub version
{
	print "$pname $FENCE_RELEASE_NAME $BUILD_DATE\n";
	print "$REDHAT_COPYRIGHT\n" if ( $REDHAT_COPYRIGHT );
	exit 0;
}


sub sendsock
{
	my ($sock, $msg, $junk) = @_;

	$sock->print($msg);
	if ($verbose)
	{
		chomp $msg;
		print "SEND: $msg\n" 
	}
}


# This will slurp up all the data on the socket.  The SSL connection 
# automatically times out after 10 seconds.  If $mode is defined, the 
# function will return immediately following the initial packet 
# terminator "<END_RIBCL/>" or "</RIBCL>" 
#    RIBCL VERSION=1.2  -> <END_RIBCL/>
#    RIBCL VERSION=2.0  -> </RIBCL>
sub receive_response
{
	my ($sock,$mode) = @_;
	$mode = 0 unless defined $mode;
	my $count=0;

	my $buf;
	my $buffer = "";

	### sock should automatically be closed by iLO after 10 seconds
	### XXX read buf length of 256.  Is this enough?  Do I need to buffer?
	while ($ssl_mod eq "Net::SSLeay::Handle" ? $buf=<$sock> : $sock->read($buf,256) )
	{
		$rd = length($buf);
		last unless ($rd);

		$buffer="$buffer$buf"; 
		if ($verbose)
		{
			chomp $buf;
			print "READ:($rd,$mode) $buf\n";
		}

		# RIBCL VERSION=1.2
		last if ( $buffer =~ /<END_RIBCL\/>$/mi && $mode==1 );

		# RIBCL VERSION=2.0
		last if ( $buffer =~ /<\/RIBCL>$/mi && $mode==1 );
	}

	### Determine version of RIBCL if not already defined
	if (!defined $ribcl_vers)
	{
		if ($buffer =~ /<RIBCL VERSION=\"([0-9.]+)\"/m)
		{
			$ribcl_vers=$1;
			print "ribcl_vers=$ribcl_vers\n" if ($verbose);
		}
		else
		{
			fail "unable to detect RIBCL version\n";
		}
	}

	return $buffer;
}


sub open_socket
{
	print "opening connection to $hostname:$port\n" if $verbose;

	if ($ssl_mod eq "Net::SSLeay::Handle")
	{
		# neat little trick I found in the man page for Net::SSLeay::Handle
		tie (*SSL,"Net::SSLeay::Handle",$hostname,$port)
			or fail "unable to connect to $hostname:$port $@\n";
		$ssl = \*SSL;
	}
	else
	{
		$ssl = Net::SSL->new( PeerAddr => $hostname,
			              PeerPort => $port );
		$ssl->configure();
		$ssl->connect($port,inet_aton($hostname)) or 
			fail "unable to connect to $hostname:$port $@\n";
	}
	return $ssl; 
}


sub close_socket
{
	my ($sock, $junk) = @_;
	#shutdown ($sock,1);
	close $sock;
}


# power_off() -- power off the node
#   return 0 on success, non-zero on failure
sub power_off
{
	my $response = set_power_state ("N");
	my @response = split /\n/,$response;
	my $no_err=0;
	my $agent_status = -1;

	foreach my $line (@response)
	{
		if ($line =~ /MESSAGE='(.*)'/)
		{
			my $msg = $1;
			if ($msg eq "No error") 
			{ 
				$no_err++;
				next; 
			}
			elsif ($msg eq "Host power is already OFF.")
			{
				$agent_status = 0;
				print "warning: $msg\n" unless defined $quiet;
			}
			else
			{
				$agent_status = 1;
				print STDERR "error: $msg\n";
			}
		}
	}

	# There should be about 6 or more response packets on a successful
	# power off command.  
	if ($agent_status<0)
	{
		$agent_status = ($no_err<5) ? 1 : 0;
	} 

	return $agent_status;
}


# power_on() -- power on the node
#   return 0 on success, non-zero on failure
sub power_on
{
	my $response = set_power_state ("Y");
	my @response = split /\n/,$response;
	my $no_err=0;
	my $agent_status = -1;

	foreach my $line (@response)
	{
		if ($line =~ /MESSAGE='(.*)'/)
		{
			my $msg = $1;
			if ($msg eq "No error") 
			{ 
				$no_err++;
				next; 
			}
			elsif ($msg eq "Host power is already ON.")
			{
				$agent_status = 0;
				print "warning: $msg\n" unless defined $quiet;
			}
			else
			{
				$agent_status = 1;
				print STDERR "error: $msg\n";
			}
		}
	}

	# There should be about 6 or more response packets on a successful
	# power on command.  
	if ($agent_status<0)
	{
		$agent_status = ($no_err<5) ? 1 : 0;
	} 

	return $agent_status;
}

# power_status() -- print the power status of the node
#   return 0 on success, non-zero on failure 
#   set $? to power status from ilo ("ON" or "OFF")
sub power_status
{
	my $response = get_power_state ();
	my @response = split /\n/,$response;
	my $agent_status = -1;
	my $power_status = "UNKNOWN";

	foreach my $line (@response)
	{
		if ($line =~ /MANAGEMENT_PROCESSOR\s*=\s*\"(.*)\"/) {
			if ($1 eq "iLO2") {
				$ilo_vers = 2;
				print "power_status: reporting iLO2\n" if ($verbose);
			}
		}

		if ($line =~ /MESSAGE='(.*)'/)
		{
			my $msg = $1;
			if ($msg eq "No error") 
			{ 
				next; 
			}
			else
			{
				$agent_status = 1;
				print STDERR "error: $msg\n";
			}
		}
		# RIBCL VERSION=1.2   
		elsif ($line =~ /HOST POWER=\"(.*)\"/)
		{
			$agent_status = 0;
			$power_status = $1;
		}

		# RIBCL VERSION=2.0   
		elsif ($line =~ /HOST_POWER=\"(.*)\"/)
		{
			$agent_status = 0;
			$power_status = $1;
		}

	}
	$_ = $power_status;
	print "power_status: reporting power is $_\n" if ($verbose);
	return $agent_status;
}

sub set_power_state
{
	my $state = shift;
	my $response = "";

	if (!defined $state || ( $state ne "Y" && $state ne "N") )
	{
		fail "illegal state\n";
	}

	$socket = open_socket;

	sendsock $socket, "<?xml version=\"1.0\"?>\r\n";
	$response = receive_response($socket,1);

	print "Sending power-o".(($state eq "Y")?"n":"ff")."\n" if ($verbose);

	if ($ribcl_vers < 2 )
	{
		sendsock $socket, "<RIBCL VERSION=\"1.2\">\n";
	}
	else
	{
		# It seems the firmware can't handle the <LOCFG> tag
		# RIBCL VERSION=2.0
		#> sendsock $socket, "<LOCFG VERSION=\"2.21\">\n";
		sendsock $socket, "<RIBCL VERSION=\"2.0\">\n";
	}
	sendsock $socket, "<LOGIN USER_LOGIN = \"$username\" PASSWORD = \"$passwd\">\n";
	sendsock $socket, "<SERVER_INFO MODE = \"write\">\n";

	if ($ilo_vers == 2) {
		# iLO2 with RIBCL v2.22 behaves differently from
		# iLO with RIBCL v2.22. For the former, HOLD_PWR_BTN is
		# used to both power the machine on and off; when the power
		# is off, PRESS_PWR_BUTTON has no effect. For the latter,
		# HOLD_PWR_BUTTON is used to power the machine off, and
		# PRESS_PWR_BUTTON is used to power the machine on;
		# when the power is off, HOLD_PWR_BUTTON has no effect.
		sendsock $socket, "<HOLD_PWR_BTN/>\n";
	}
	# As of firmware version 1.71 (RIBCL 2.21) The SET_HOST_POWER command
	# is no longer available.  HOLD_PWR_BTN and PRESS_PWR_BTN are used 
	# instead now :(
	elsif ($ribcl_vers < 2.21)
	{
		sendsock $socket, "<SET_HOST_POWER HOST_POWER = \"$state\"/>\n";
	}
	else
	{
		if ($state eq "Y" )
		{ 
			sendsock $socket, "<PRESS_PWR_BTN/>\n";
		} 
		else 
		{
			sendsock $socket, "<HOLD_PWR_BTN/>\n";
		}
	}

	sendsock $socket, "</SERVER_INFO>\n";
	sendsock $socket, "</LOGIN>\n";
	sendsock $socket, "</RIBCL>\n";

	# It seems the firmware can't handle the <LOCFG> tag
	# RIBCL VERSION=2.0
	#> sendsock $socket, "</LOCFG>\n" if ($ribcl_vers >= 2) ;

	$response = receive_response($socket);

	print "Closing connection\n" if ($verbose);
	close_socket($socket);

	return $response;
}

sub get_power_state
{
	my $response = "";

	$socket = open_socket;

	sendsock $socket, "<?xml version=\"1.0\"?>\r\n";
	$response = receive_response($socket,1);

	print "Sending get-status\n" if ($verbose);

	if ($ribcl_vers < 2 )
	{
		sendsock $socket, "<RIBCL VERSION=\"1.2\">\n";
	}
	else
	{
		# It seems the firmware can't handle the <LOCFG> tag
		# RIBCL VERSION=2.0
		#> sendsock $socket, "<LOCFG VERSION=\"2.21\">\n";
		sendsock $socket, "<RIBCL VERSION=\"2.0\">\n";
	}
	sendsock $socket, "<LOGIN USER_LOGIN = \"$username\" PASSWORD = \"$passwd\">\n";
	if ($ribcl_vers >= 2) {
	    sendsock $socket, "<RIB_INFO MODE=\"read\"><GET_FW_VERSION/></RIB_INFO>\n";
	}
	sendsock $socket, "<SERVER_INFO MODE = \"read\">\n";
	sendsock $socket, "<GET_HOST_POWER_STATUS/>\n";
	sendsock $socket, "</SERVER_INFO>\n";
	sendsock $socket, "</LOGIN>\n";
	sendsock $socket, "</RIBCL>\n";

	# It seems the firmware can't handle the <LOCFG> tag
	# RIBCL VERSION=2.0
	#> sendsock $socket, "</LOCFG>\r\n" if ($ribcl_vers >= 2) ;

	$response = receive_response($socket);

	print "Closing connection\n" if ($verbose);
	close_socket($socket);
    
	return $response;
}


sub get_options_stdin
{
	my $opt;
	my $line = 0;
	while( defined($in = <>) )
	{
		$_ = $in;

		chomp;

		# strip leading and trailing whitespace
		s/^\s*//;
		s/\s*$//;

		# skip comments
		next if /^#/;

		$line+=1;
		$opt=$_;
		next unless $opt;

		($name,$val)=split /\s*=\s*/, $opt;

		if ( $name eq "" )
		{
			print STDERR "parse error: illegal name in option $line\n";
			exit 2;
		}

		elsif ($name eq "action" )
		{
				$action = $val;
		}

		# DO NOTHING -- this field is used by fenced or stomithd
		elsif ($name eq "agent" ) { }

		elsif ($name eq "hostname" )
		{
			$hostname = $val;
		}
		elsif ($name eq "login" )
		{
			$username = $val;
		}
		elsif ($name eq "passwd" )
		{
			$passwd = $val;
		}
		elsif ($name eq "passwd_script" )
		{
			$passwd_script = $val;
		}
		elsif ($name eq "ribcl" )
		{
			$ribcl_vers = $val;
		}
		elsif ($name eq "verbose" )
		{
			$verbose = $val;
		}

	}
}

################################################################################
# MAIN

$action = "reboot";
$ribcl_vers = undef; # undef = autodetect
$ilo_vers = 1;

if (@ARGV > 0) {
	getopts("a:hl:n:o:p:S:r:qvV") || fail_usage ;

	usage if defined $opt_h;
	version if defined $opt_V;

	fail_usage "Unkown parameter." if (@ARGV > 0);

	fail_usage "No '-a' flag specified." unless defined $opt_a;
	$hostname = $opt_a;

	fail_usage "No '-l' flag specified." unless defined $opt_l;
	$username = $opt_l;

	if (defined $opt_S) {
		$pwd_script_out = `$opt_S`;
		chomp($pwd_script_out);
		if ($pwd_script_out) {
			$opt_p = $pwd_script_out;
		}
	}

	fail_usage "No '-p' or '-S' flag specified." unless defined $opt_p;
	$passwd   = $opt_p;

	$action = $opt_o if defined $opt_o;
	fail_usage "Unrecognised action '$action' for '-o' flag"
		unless $action=~ /^(off|on|reboot|status)$/;

	$localport = $opt_n if defined $opt_n;

	$quiet = 1 if defined $opt_q;

	$verbose = 1 if defined $opt_v;

	$ribcl_vers = $opt_r if defined $opt_r;

} else {
	get_options_stdin();

	fail "no host\n" unless defined $hostname;
	fail "no login name\n" unless defined $username;

	if (defined $passwd_script) {
		$pwd_script_out = `$passwd_script`;
		chomp($pwd_script_out);
		if ($pwd_script_out) {
			$passwd = $pwd_script_out;
		}
	}

	fail "no password\n" unless defined $passwd;

	fail "unrecognised action: $action\n"
		unless $action=~ /^(off|on|reboot|status)$/;
}

# Parse user specified port from apaddr parameter
($hostname_tmp,$port,$junk) = split(/:/,$hostname); 
fail "bad hostname/ipaddr format: $hostname\n" if defined $junk;
$hostname = $hostname_tmp;
$port = 443 unless defined $port;

print "ssl module: $ssl_mod\n" if $verbose;


$_=$action;
if (/on/)
{
	fail "power_status: unexpected error\n" if power_status;

	if (! /^on$/i)
	{
		fail "power_on: unexpected error\n" if power_on;
		fail "power_status: unexpected error\n" if power_status;
		fail "failed to turn on\n" unless (/^on$/i); 
	}
	else
	{
		print "power is already on\n" unless defined $quiet;
	}
}
elsif (/off/)
{
	fail "power_status: unexpected error\n" if power_status;

	if (! /^off$/i)
	{
		fail "power_off: unexpected error\n" if power_off;
		fail "power_status: unexpected error\n" if power_status;
		fail "failed to turn off\n" unless (/^off$/i); 
	}
	else
	{
		print "power is already off\n" unless defined $quiet;
	}
}
elsif (/reboot/)
{
	fail "power_status: unexpected error\n" if power_status;

	if (! /^off$/i)
	{
		fail "power_off: unexpected error\n" if power_off;
		fail "power_status: unexpected error\n" if power_status;
		fail "failed to turn off\n" unless (/^off$/i); 
	}

	if (/^off$/i)
	{
		fail "power_on: unexpected error\n" if power_on;
		fail "power_status: unexpected error\n" if power_status;
		fail "failed to turn on\n" unless (/^on$/i); 
	}
	else
	{
		fail "unexpected power state: '$_'\n";
	}
}
elsif (/status/)
{
	fail "power_status: unexpected error\n" if power_status;
	print "power is $_\n";
}
else
{
	fail "illegal action: '$_'\n";
}

print "success\n" unless defined $quiet;
exit 0

################################################################################
