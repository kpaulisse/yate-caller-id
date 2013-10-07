#!/usr/bin/perl

########################################################################
# Caller ID Name (CNAM) lookup script.
# See: http://blog.paulisse.com/2013/09/custom-caller-id-names-with-google_15.html
# Copyright (c) 2013, Kevin W. Paulisse, all rights reserved
#
# Licensed under the same terms as perl itself, which means your choice of:
# a) the GNU General Public License as published by the Free Software Foundation;
#    either version 1, or (at your option) any later version, or
# b) the "Artistic License".
########################################################################
use strict;
use lib '/usr/share/yate/scripts';
use JSON;
use LWP::UserAgent;
use FindBin qw($Bin);
use lib $Bin;
use Yate;
use vars qw(%CFG %CNAM_CACHE);

#
# Usage: caller-id.pl <configfile>
#

%CFG = ();
if (defined($ARGV[0])) {
	open(my $CONFIG, "<", $ARGV[0]) or die "Failed to open config file: $!";
	my @cfg = <$CONFIG>;
	close($CONFIG);
	foreach my $line (@cfg) {
		next if $line !~ /^\s*(\w+)\s*=\s*"?(\S+)"?\s*$/;
		$CFG{$1} = $2;
	}
} else {
	die "Usage: $0 <configfile>\n";
}

#
# Initialize cache
#

read_cache();

#
# Set up preroute handler.  Assumes the incoming number is
#     join('/', <your google voice number>, <the caller's number>)
#
# Look up phone number in:
# - custom map
# - opencnam.com
# - default/unknown
#

sub call_preroute_handler {
	my $message = shift;
	my ($googlenum, $phonenum) = split(/\//, $message->param('called'));
	log_message("Call to google number <$googlenum> from phone number <$phonenum>");

	my $prefix = defined $CFG{'PREFIX_STR'} ? $CFG{'PREFIX_STR'} : '00';
	if (open(my $PF, '<', $CFG{'PREFIX_MAP'})) {
		my @pf = <$PF>;
		close($PF);
		foreach my $line (@pf) {
			my ($phone, $pref) = split(/[\s\=]+/, $line);
			next if $phone ne $googlenum;
			$prefix = sprintf('%02d', $pref);
		}
	}
	log_message("Prefix set to $prefix");

	if (defined($phonenum) && $phonenum =~ /\d/) {

		# Look up in custom map
		my $caller = lookup_custom_map($phonenum);

		# Not found in custom map?
		if (!defined($caller)) {

			# Cached?
			if (defined($CNAM_CACHE{$phonenum})) {
				my $name       = $CNAM_CACHE{$phonenum}->{'name'};
				my $lookuptime = $CNAM_CACHE{$phonenum}->{'time'};
				my $default_ttl = defined($CFG{'CNAM_CACHE_TTL'}) ? $CFG{'CNAM_CACHE_TTL'} : 30 * 86400;
				if ((time - $lookuptime) < $default_ttl) {
					log_message("Found $phonenum in cache; name is $name");
					$caller = $name;
				} else {
					log_message("Found $phonenum in cache; name is $name; record EXPIRED");
				}
			}

			# If still unknown, look up in opencnam
			$caller = lookup_opencnam($phonenum) if !defined($caller);

			# Save cache if found
			save_cache($phonenum, $caller) if defined($caller);

			# Handle unknown callers
			$caller = $CFG{'UNKNOWN_CALLER_NAME'} if !defined($caller);
			$caller = 'Unknown' if !defined($caller);
		}
		$message->param('callername', substr($caller, 0, 15));
		$message->param('caller', $prefix . $phonenum);
	} else {
		$message->param('callername', 'Invalid');
		$message->param('caller',     $prefix . '0000000000');
	}
	return 1;
}

#
# Using Yate.pm
#

log_message("Starting up");
my $message = Yate->new;
$message->install('call.preroute', \&call_preroute_handler, 1);
$message->listen();
log_message("Error! Fell out of \$message->listen()");
exit(1);

#
# Look up phone number in simple text file for custom names.
# Reads the file upon each call (to avoid having to reload YATE
# when the map is updated).
#

sub lookup_custom_map {
	my $PHONENUM = shift;
	return if !defined $CFG{'CUSTOM_MAP'};
	log_message("Entering lookup_custom_map() for $PHONENUM");
	my $CUSTOMMAP = $CFG{'CUSTOM_MAP'};
	if (open(my $fh, "<", $CUSTOMMAP)) {

		# Can't use $_ because it screws up Yate.pm (ouch!)
		my @custommap = <$fh>;
		close($fh);
		foreach my $line (@custommap) {
			next if $line =~ /^\s*#/;
			next if $line =~ /^\s*$/;
			$line =~ s/^\s+//;
			$line =~ s/\s+$//;
			my ($phone, $name) = split(/\s+/, $line, 2);
			if ($phone eq $PHONENUM) {
				close($fh);
				log_message("lookup_custom_map() match: $name");
				return $name;
			}
		}
		close($fh);
		log_message("Number not found in custom map");
		return;
	}
	log_message("No custom map <$CUSTOMMAP>");
	return;
}

#
# Look up phone number with opencnam.com
#

sub lookup_opencnam {
	my $PHONENUM = shift;
	return if !defined $CFG{'OPENCNAM_URL'};
	log_message("Entering lookup_opencnam() for $PHONENUM");
	$PHONENUM =~ s/([^\d\-])/sprintf('%%%02x', ord($1))/ge;

	# Construct the URL
	my $url = sprintf($CFG{'OPENCNAM_URL'}, $PHONENUM);
	if (defined($CFG{'OPENCNAM_ACCOUNT_SID'}) && defined($CFG{'OPENCNAM_AUTH_TOKEN'})) {
		$url .= sprintf('&account_sid=%s&auth_token=%s', $CFG{'OPENCNAM_ACCOUNT_SID'}, $CFG{'OPENCNAM_AUTH_TOKEN'});
		log_message("opencnam professional tier");
	} else {
		log_message("opencnam hobby tier");
	}

	# Use LWP to retrieve the data
	my $ua = LWP::UserAgent->new;
	$ua->timeout(3);
	my $response = $ua->get($url);

	# Handle success of URL fetch
	if ($response->is_success) {
		log_message("Received content from opencnam");
		my $c    = $response->content;
		my $json = JSON->new->allow_nonref;
		my $data = $json->decode($response->content);
		if (ref($data) eq 'HASH') {
			log_message("Received name from opencnam: " . $data->{'name'});
			$CNAM_CACHE{$PHONENUM} = { 'name' => $data->{'name'}, 'time' => time };
			return $data->{'name'};
		}
		log_message("Received invalid data from opencnam: " . $response->content);
		return;
	}

	# Handle failure of URL fetch
	log_message("Received error from opencnam: " . $response->status_line);
	return;
}

#
# Formatting of messages into the log file
#

sub log_message {
	my @messages = @_;
	return if !defined($CFG{'LOGFILE'});
	my $LOGFILE = $CFG{'LOGFILE'};
	my ($sec, $min, $hr, $day, $mon, $year) = localtime(time);
	my @output = ();
	foreach my $message (@messages) {
		next if $message !~ /\S/;
		$message =~ s/\s+$//;
		$message =~ s/^\s+//;
		push @output, sprintf "%04d/%02d/%02d %02d:%02d:%02d %s\n", $year + 1900, $mon + 1, $day, $hr, $min, $sec, $message;
	}

	if (open(my $logfile_fh, ">>", $LOGFILE)) {
		print $logfile_fh @output;
		close($logfile_fh);
	}
	return;
}

#
# Store numbers and names that we had to look up - maybe we want
# to add these to the custom file, or maybe we want to cache them.
# This reduces expense of looking up the same numbers over and over.
#

sub save_cache {
	my ($PHONENUM, $CALLER) = @_;
	return if !defined $CFG{'HINTFILE'};
	return if !defined($PHONENUM) || !defined($CALLER);
	return if $CALLER !~ /\S/;
	$CALLER   =~ s/^\s+//;
	$CALLER   =~ s/\s+$//;
	$PHONENUM =~ s/\s+/ /g;
	$CALLER   =~ s/\s+/ /g;
	my $HINTFILE = $CFG{'HINTFILE'};

	if (open(my $lock_fh, ">", "$HINTFILE.lock")) {
		flock($lock_fh, 2);

		my @cachefile = ();
		if (open(my $hint_fh, "<", $HINTFILE)) {
			@cachefile = <$hint_fh>;
			close($hint_fh);
		}

		my @output  = ();
		my $written = 0;
		foreach my $line (@cachefile) {
			my ($phonenum, $caller, $timestamp, $comment) = split(/\t/, $line, 4);
			if ($phonenum ne $PHONENUM) {
				push @output, $line;
			} else {
				push @output, sprintf "%s\t%s\t%d\t%s\n", $PHONENUM, $CALLER, time, scalar localtime(time);
				$written = 1;
			}
		}
		if (!$written) {
			push @output, "%s\t%s\t%d\t%s\n", $PHONENUM, $CALLER, time, scalar localtime(time);
		}

		if (open(my $hint_fh, ">", $HINTFILE)) {
			print $hint_fh @output;
			close($hint_fh);
		}

		flock($lock_fh, 8);
		close($lock_fh);
	}
	return;
}

#
# Read cache
#

sub read_cache {
	return if !defined $CFG{'HINTFILE'};
	my $HINTFILE = $CFG{'HINTFILE'};
	if (open(my $hint_fh, "<", $HINTFILE)) {
		my @cachefile = <$hint_fh>;
		close($hint_fh);
		foreach my $line (@cachefile) {
			my ($phonenum, $caller, $timestamp, $comment) = split(/\t/, $line, 4);
			$CNAM_CACHE{$phonenum} = { 'name' => $caller, 'time' => $timestamp };
		}
	}
	return;
}
