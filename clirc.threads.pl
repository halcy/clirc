# clirc.pl - A cl chat IRC passthrough server
# Incredibly hacky, use at your own risk. Probably not MUCH worse than the web
# client, though so it should be okay to use.
#
# Essentially, just input a username and password, run, then connect your
# IRC client to port 7070 and give pass and user of the user you want to log
# in as. Server is entirely multi-user capable now, can log out/in, etc.
#
# What do you mean, 30 lines of printf are not an IRC server?
#
# KNOWN BUGS: * Does not hit offline.
#             * User list is not updated right at all.
#             * Nicknames with spaces in them are a problem.
#             * Spaces are a problem in general.
#             * So is upper/lowercase.
#             * Nick list is sometimes not send right, I wonder what's up with
#               that.
#
# (c) 2011 Lorenz Diener, lorenzd@gmail.com
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License or any later
# version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

##############################################
# CONFIG
##############################################

# Base user and PW. Pull requests will come from this user.
# Should be distinct from every other user, preferably.
my $user = "halcy";
my $password = "";

##############################################

use strict;
use warnings;

use threads;
use threads::shared;
use Thread::Queue;

use JSON;
use Encode;

use LWP::UserAgent;
use DateTime::Format::HTTP;
use HTTP::Cookies;

use IO::Socket;
use IO::Select;
use Data::Dumper;

# Create queue for runner
my $to_irc = Thread::Queue->new();
my $to_cl = Thread::Queue->new();

# Set up a LWP to request things from the colorless chat
sub makeclobj {
	my $cl;
	$cl = LWP::UserAgent->new();

	$cl->agent("clirc.pl");
	$cl->timeout(2);

	login($cl, $user, $password, 1);

	return $cl;
}

# Log in to cl
sub login {
	my $cl = shift();
	my $uname = shift();
	my $pwd = shift();
	my $noonline = shift();
	
	my $jar = HTTP::Cookies->new();
	$cl->cookie_jar( $jar );
	
	$cl->post(
		'http://thecolorless.net/login',
		[
			'userName' => $uname,
			'userPassword' => $pwd,
			'ref' => 'http%253A%252F%252Fthecolorless.net%252F',
		]
	);

	# Get cookies up and running
	$cl->cookie_jar->set_cookie(undef, "username", $uname, "/", "thecolorless.net", undef, 0, 0, 60*60, 0);
	$cl->cookie_jar->set_cookie(undef, "color", "gravatar", "/", "thecolorless.net", undef, 0, 0, 60*60, 0);
	$cl->cookie_jar->set_cookie(undef, "kjhdf", "1", "/", "thecolorless.net", undef, 0, 0, 60*60, 0);

	$cl->get('http://thecolorless.net/chat');

	# Hit online
	if(!defined $noonline || $noonline == 0) {
		$cl->get('http://thecolorless.net/chat/hit/online/0');
	}

	return $jar;
}

# CL Chat Runner
sub clgetthread {
	# Fabricate CL object and log in initial user.
	my $cl = makeclobj();
	my $requestjar = $cl->cookie_jar;
	my %userjars = ();
	
	# Grab the initial user list
	my $userlist = decode_utf8( $cl->get('http://thecolorless.net/chat/get_online')->content() );
	my $userhash = decode_json( $userlist );
	my @users_prep = @{ $userhash->{users} };
	my @users = ();
	foreach( @users_prep ) {
		my %thisuser = %{ $_ };
		if( $thisuser{chatChannel} eq '0' ) {
			my $thisusername = $thisuser{chatUser};
			if( $thisusername ne $user ) {
				push @users, $thisusername;
			}
		}
	}
	$to_irc->enqueue(\@users);

	# Loop go.
	my $lastmsg = "";
	my $lastmod = undef;
	while(1) {
		# Yield for others.
		threads->yield();
		sleep(1);
		
		# Get new things.
		my $msggreq = HTTP::Request->new(
			GET => 'http://thecolorless.net/chat/comet_pull?channel=0'
		);
		$msggreq->referer( 'http://thecolorless.net/chat');
		$msggreq->header( 'If-Modified-Since', $lastmod );

		$cl->cookie_jar($requestjar);
		my $response = $cl->request($msggreq);
		
		if ($response->is_success) {
			my $data = decode_utf8($response->decoded_content());
			my $msgd = decode_json( $data );
			if( $msgd && !($data =~ /^\s*$/ ) ) {
				my $msgs;
				if( ref($msgd) ne 'ARRAY' ) {
					$msgs = [ $msgd ];
				}
				else {
					$msgs = $msgd;
				}

				# Translate to IRC, shove into queue, avoid duplicates
				my $thismsg = "";
				foreach my $msg (@{$msgs}) {
					my $from;
					if( lc( $msg->{type} ) eq 'message' ) {
						my $msgtext = $msg->{text};
						$msgtext =~ s/<a href="([^"]*)"[^>]*>[^<]*<\/a>/$1/gi;
						$msgtext =~ s/&quot;/"/gi;
						$msgtext =~ s/&lt;/</gi;
						$msgtext =~ s/&gt;/>/gi;
						$msgtext =~ s/&amp;/&/gi;
						$from = $msg->{nickname};
						my $ircfrom = $from;
						$ircfrom =~ s/[^a-zA-Z0-9\-]/_/gi;
						$thismsg = ":" . $ircfrom. " PRIVMSG #colorless :" .$msgtext . "\n";
					}
					elsif( lc( $msg->{type} ) eq 'join' ) {
						$from = $msg->{nickname};
						my $ircfrom = $from;
						$ircfrom =~ s/[^a-zA-Z0-9\-]/_/gi;
						$thismsg = ":$ircfrom!$ircfrom" . '@irc.colorless JOIN :#colorless' . "\n";
					}
					elsif( lc( $msg->{type} ) eq 'leave' ) {
						$from = $msg->{nickname};
						my $ircfrom = $from;
						$ircfrom =~ s/[^a-zA-Z0-9\-]/_/gi;
						$thismsg = ":$ircfrom!$ircfrom" . '@irc.colorless PART #colorless' . "\n";
					}
					
					if( $lastmsg ne $thismsg ) {
						$lastmod = $response->header("Last-Modified");
						my @req = ("message", $from, $thismsg);
						$to_irc->enqueue(\@req);
						$lastmsg = $thismsg;
					}
					else {
						my $class = 'DateTime::Format::HTTP';
						my $time = $class->parse_datetime( $lastmod );
						$time->add( seconds => 1 );
						$lastmod = $class->format_datetime( $time );
					}
				}
			}
		}

		# Handle input from IRC thread(s) to CL
		while(defined(my $item = $to_cl->dequeue_nb())) {
			threads->yield();
			my @request = @{$item};
			my $type = shift(@request);
			my $req;
			my $nick;
			if($type eq "login") {
				my $mname = shift(@request);
				my $pwd = shift(@request);
				my $jar = login($cl, $mname, $pwd);
				print "Login: $mname -> [HIDDEN]\n";
				$userjars{$mname} = $jar;
				next;
			}
			elsif($type eq "logout") {
				# TODO hit offline
				next;
			}
			elsif($type eq "message") {
				my $nickname = shift(@request);
				$nick = $nickname;
				my $message = shift(@request);
				$req = HTTP::Request->new(
					POST => 'http://thecolorless.net/chat/publish/0'
				);
				$req->content_type('application/x-www-form-urlencoded');
				$req->content( 'message=' . $message );
				$req->referer( 'http://thecolorless.net/chat');
				$req->header( 'Origin', 'http://thecolorless.net' );
				$req->header( 'Accept', '*/*' );
				$req->header( 'X-Requested-With', 'XMLHttpRequest' );
			}
			elsif($type eq "kick") {
				my $nickname = shift(@request);
				$nick = $nickname;
				my $whom = shift(@request);
				$req = HTTP::Request->new(
					POST => 'http://thecolorless.net/chat/kick/0'
				);
				$req->content_type('application/x-www-form-urlencoded');
				$req->content( 'nickname=' . $whom );
				$req->referer( 'http://thecolorless.net/chat');
				$req->header( 'Origin', 'http://thecolorless.net' );
				$req->header( 'Accept', '*/*' );
				$req->header( 'X-Requested-With', 'XMLHttpRequest' );
			}

			print "Setting |$nick| jar\n";
			$cl->cookie_jar($userjars{$nick});
			$cl->cookie_jar->set_cookie(undef, "username", $nick, "/", "thecolorless.net", undef, 0, 0, 60*60, 0);
			$cl->cookie_jar->set_cookie(undef, "color", "gravatar", "/", "thecolorless.net", undef, 0, 0, 60*60, 0);
			$cl->cookie_jar->set_cookie(undef, "kjhdf", "1", "/", "thecolorless.net", undef, 0, 0, 60*60, 0);

			my $response = $cl->request($req);
		}
	}
}

# Single user runner
sub handleuser {
	my $sock = shift();
	my @users = @_;
	my $logged_in = 0;
	$sock->blocking(0);
	
	print "New connection\n";
	
	# The hackiest IRCd
	my $nname = "";
	my $pwd = "";
	print $sock ":irc.colorless 439 * :Please wait while we process your connection.\n";
	print $sock ":irc.colorless NOTICE AUTH :*** Oh my god, it's full of stars...\n";
	sleep(4);

	# Create message queue and register with dispatcher.
	my $to_local = Thread::Queue->new();

	# Create socket selecter
	my $s = IO::Select->new();
	$s->add($sock);

	my $break = 0;
	while(defined $sock->connected() && !$break) {
		# Yield for others
		threads->yield();
		sleep(1);
		# print "IRC reader running\n";
		my $line;

		# Handle input from IRC
		while( $s->can_read(0.1) ) {
		#	print "Read running\n";
			$line = <$sock>;
			my $first = 1;
			while(defined $line && $line ne "") {
				threads->yield();
				$first = 0;
				chomp $line;
				if( $line =~ /PING (.*)/i ) {
					print $sock ":irc.colorless PONG $1\n";
				}
				elsif( $line =~ /PRIVMSG #colorless :(.*)/i ) {
					my @req = ("message", $nname, $1);
					$to_cl->enqueue(\@req);
				}
				elsif( $line =~ /KICK #colorless :?(.*)/i ) {
					my @req = ("kick", $nname, $1);
					$to_cl->enqueue(\@req);
				}
				elsif( $line =~ /WHO (.*)/i ) {
					my $requser = $1;
					print $sock ":irc.colorless 352 $user #colorless $requser irc.colorless * $requser H :0 $requser\n";
					print $sock ":irc.colorless 315 $user $requser :End of /WHO list.\n";

				}
				elsif( $line =~ /NICK .*?([a-zA-Z0-9_]*).*?$/i ) {
					print "Got nick $1\n";
					if($nname eq "") {
						print "Setting $1\n";
						$nname = $1;
					}
				}
				elsif( $line =~ /PASS .*?([a-zA-Z0-9_]*).*?$/i ) {
					print "Got pass [HIDDEN]\n";
					$pwd = $1;
				}
				elsif( $line =~ /MODE #colorless \+b/i ) {
					print $sock ":irc.colorless 368 $user #colorless :End of Channel Ban List\n";
				}
				elsif( $line =~ /MODE/i ) {
					print $sock ":irc.colorless 324 $user #colorless +nt\n";
					print $sock ":irc.colorless 329 $user #colorless 1305153130\n";
				}
				$line = <$sock>;
			}
			
			if(!defined $line && $first) {
				$break = 1;
				next;
			}
		}

		if($logged_in == 0 && $pwd ne "" && $nname ne "") {
			$logged_in = 1;
			
			print $sock ":irc.colorless 001 $nname :Welcome to the Colorless chat. Don't be a dick.\n";
			print $sock ":$nname!$nname" . '@localhost JOIN :#colorless' . "\n";
			sleep(2);
			print $sock ":irc.colorless 353 $nname = #colorless :$nname\n";
			foreach( @users ) {
				print $sock ":irc.colorless 353 $nname = #colorless :$_\n";
			}
			sleep(1);
			print $sock ":irc.colorless 366 $nname #colorless :End of /NAMES list.\n";
			sleep(1);
			print $sock ":irc.colorless 332 $nname #colorless :Welcome to the colorless chat | using clirc.pl\n";
			sleep(1);

			print "Requesting register: |$nname| / $pwd\n";
			my @req = ("register", $nname, $pwd, $to_local);
			$to_irc->enqueue(\@req);
		}

		# Handle input from CL thread to IRC.
		while(defined(my $item = $to_local->dequeue_nb())) {
			threads->yield();
			print $sock $item;
		}

	}
	close($sock);

	my @req = ("terminate", $nname);
	$to_irc->enqueue(\@req);

}

# Message dispatcher
sub dispatcher() {
	my %queues = ();
	
	while(1) {
		threads->yield();
		sleep(1);
		while(defined(my $item = $to_irc->dequeue_nb())) {
			threads->yield();
			my @request = @{$item};
			my $type = shift(@request);
			my $req;
			if($type eq "message") {
				my $from = shift(@request);
				my $msg = shift(@request);
				print "New message $from\n";
				foreach(keys %queues) {
					if(defined $queues{$_} && $_ ne $from) {
						print "Pushing to $_\n";
						$queues{$_}->enqueue($msg);
					}
				}
			}
			elsif($type eq "register") {
				my $name = shift(@request);
				my $pwd = shift(@request);
				my $queueref = shift(@request);
				print "Registering $name\n";
				$queues{$name} = $queueref;
				my @req = ("login", $name, $pwd);
				$to_cl->enqueue(\@req);
			}
			elsif($type eq "terminate") {
				my $name = shift(@request);
				print "Terminating $name\n";
				delete $queues{$name};
			}
		}
	}
}

# IRC runner
sub ircthread {
	# IRC side of things, wait for connections on port 7070
	my $serv = new IO::Socket::INET (
		LocalPort => '7070',
		Proto => 'tcp',
		Listen => 1,
		Reuse => 1,
	);
	die "Could not create socket: $!\n" unless $serv;

	# Grab initial user list.
	my @users = @{ $to_irc->dequeue() };

	# Begin dispatcher thread
	threads->create( \&dispatcher )->detach();

	while(1) {
		# Yield for others
		threads->yield();

		print "Socket accepter running\n";
		
		# Grab a new client
		my $sock =  $serv->accept();
		if(defined $sock) {
			threads->create( \&handleuser, $sock, @users )->detach();
		}
	}	
}

my $sockthread = threads->create( \&ircthread )->detach();
my $clthread = threads->create( \&clgetthread )->detach();

while(1){ sleep(1); };
