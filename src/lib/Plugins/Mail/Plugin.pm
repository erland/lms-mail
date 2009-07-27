# 				Mail plugin 
#
#    Copyright (c) 2007 Erland Isaksson (erland_i@hotmail.com)
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, write to the Free Software
#    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

package Plugins::Mail::Plugin;

use strict;

use base qw(Slim::Plugin::Base);

use Slim::Utils::Prefs;
use Slim::Buttons::Home;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Unicode;
use File::Spec::Functions qw(:ALL);
use File::Slurp;
use HTTP::Date qw(time2str);
use Net::IMAP::Simple;
use Mail::POP3Client;
use Email::Simple;
use Crypt::Tea;
use Plugins::Mail::Template::Reader;
use Date::Parse;
use Time::Local;

use Plugins::Mail::Settings;

use Slim::Schema;
use Data::Dumper;

my $prefs = preferences('plugin.mail');
my $serverPrefs = preferences('server');
my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.mail',
	'defaultLevel' => 'WARN',
	'description'  => 'PLUGIN_MAIL',
});

# Information on each portable library
my $htmlTemplate = 'plugins/Mail/index.html';
my $PLUGINVERSION = undef;

my $ICONS = {};
my $driver;
my $cache = undef;

sub getDisplayName {
	return 'PLUGIN_MAIL';
}

sub initPlugin {
	my $class = shift;
	$class->SUPER::initPlugin(@_);
	$PLUGINVERSION = Slim::Utils::PluginManager->dataForPlugin($class)->{'version'};
	Plugins::Mail::Settings->new($class);

	checkDefaults();

	$driver = $serverPrefs->get('dbsource');
	$driver =~ s/dbi:(.*?):(.*)$/$1/;
    
	if(UNIVERSAL::can("Slim::Schema","sourceInformation")) {
		my ($source,$username,$password);
		($driver,$source,$username,$password) = Slim::Schema->sourceInformation;
	}
	if($driver ne 'mysql') {
		eval "require DBIx::Class::Storage::DBI::mysql;";
		if($@) {
			$log->error("Unable to load MySQL driver: $@");
		}
	}
}


sub webPages {

	my %pages = (
		"Mail/index\.(?:htm|xml)"     => \&handleWebList,
	);

	for my $page (keys %pages) {
		if(UNIVERSAL::can("Slim::Web::Pages","addPageFunction")) {
			Slim::Web::Pages->addPageFunction($page, $pages{$page});
		}else {
			Slim::Web::HTTP::addPageFunction($page, $pages{$page});
		}
	}
	Slim::Web::Pages->addPageLinks("plugins", { 'PLUGIN_MAIL' => 'plugins/Mail/index.html' });
}


# Draws the plugin's web page
sub handleWebList {
	my ($client, $params) = @_;

	my $messages = getMailMessagesWithDefaultCredentials(1);

	$params->{'pluginMailItems'} = $messages;
	$params->{'pluginMailVersion'} = $PLUGINVERSION;
	if(defined($params->{'redirect'})) {
		return Slim::Web::HTTP::filltemplatefile('plugins/Mail/mail_redirect.html', $params);
	}else {
		return Slim::Web::HTTP::filltemplatefile($htmlTemplate, $params);
	}
}

sub getMailMessagesWithDefaultCredentials {
	my $onlyHeaders = shift;

	my $mailHost = $prefs->get('mailhost');
	my $mailAccount = $prefs->get('mailaccount');
	my $mailType = $prefs->get('mailtype');
	my $mailFolder = $prefs->get('mailfolder');
	my $mailPassword = $prefs->get('mailpassword');
	if(defined $mailPassword) {
		$mailPassword = decrypt($mailPassword,"Six by nine. Forty two.");
	}
	my @empty = ();
	my $messages = \@empty;
	if($mailHost && $mailAccount && $mailType && $mailPassword) {
		$messages = getMailMessages($mailHost,$mailType,$mailAccount,$mailPassword,$mailFolder,$onlyHeaders);
	}
	return $messages;
}

sub getMailMessages {
	my $mailHost = shift;
	my $mailType = shift;
	my $mailAccount = shift;
	my $mailPassword = shift;
	my $mailFolder = shift;
	my $onlyHeaders = shift;

	if(!defined($mailFolder) || $mailFolder eq '') {
		$mailFolder = 'INBOX';
	}

	if($mailType eq "IMAPS") {
		if($mailHost !~ /:/) {
			$mailHost .= ":993";
		}
	}

	if(!defined($cache)) {
		$cache = Slim::Utils::Cache->new();
	}

	my @empty = ();
	my $messages = \@empty;

	my $cachedMessages = undef;
	if($onlyHeaders) {
		my $timestamp = $cache->get("$mailHost:$mailType:$mailAccount:$mailFolder-headers-timestamp");
		my $pollingInterval = $prefs->get('pollinginterval');
		if(!defined($timestamp) || $timestamp>(time()-($prefs->get('pollinginterval')*60))) {
			$cachedMessages = $cache->get("$mailHost:$mailType:$mailAccount:$mailFolder-headers");
		}
	}

	if(defined($cachedMessages)) {
		$messages = $cachedMessages;
	}else {
		my $imap = undef;
		my $pop3 = undef;
		if($mailType eq "IMAPS") {
			$log->debug("Logging in to $mailHost using IMAPS...");
			$imap = Net::IMAP::Simple->new($mailHost, use_ssl => 1);
		}elsif($mailType eq 'IMAP') {
			$log->debug("Logging in to $mailHost using IMAP...");
			$imap = Net::IMAP::Simple->new($mailHost);
		}elsif($mailType eq 'POP3') {
			$log->debug("Logging in to $mailHost using POP3...");
			$pop3 = Mail::POP3Client->new(USER => $mailAccount, PASSWORD => $mailPassword, HOST => $mailHost);
		}elsif($mailType eq 'POP3S') {
			$log->debug("Logging in to $mailHost using POP3S...");
			$pop3 = Mail::POP3Client->new(USER => $mailAccount, PASSWORD => $mailPassword, HOST => $mailHost, USESSL => 1);
		}
		if($imap) {
			$log->debug("Logging in...");
			if($imap->login($mailAccount,$mailPassword)) {
				$log->debug("Logged in successfully");
				my ($unseen, $recent, $num_messages) = $imap->status($mailFolder);

				$log->debug("$unseen unseen messages, $recent recent messages and totally $num_messages messages");
	
				my $nm = $imap->select($mailFolder);
				$log->debug("Totally $nm messages");
		
				for(my $i = $nm;$i > 0; $i--) {
					my $message = " ";
					if(!$imap->seen($i)) {
						my $es = Email::Simple->new(join '', @{$imap->top($i)});
						my $message = {};
						$message->{'From'} = $es->header('From');
						$message->{'To'} = $es->header('To');
						$message->{'Date'} = $es->header('Date');
						my $time = timegm(strptime($message->{'Date'}));
						$message->{'Date'} = Slim::Utils::DateTime::shortDateF($time).' '.Slim::Utils::DateTime::timeF($time);
						$message->{'Subject'} = $es->header('Subject');
						push @$messages,$message;
					}
					if(scalar(@$messages)==$unseen) {
						last;
					}
				}
				$cache->set("$mailHost:$mailType:$mailAccount:$mailFolder-headers",$messages);
				$cache->set("$mailHost:$mailType:$mailAccount:$mailFolder-headers-timestamp",time());
			}else {
				$log->error("Login failed: ".$imap->errstr);
			}
			$imap->quit();
		}elsif($mailType eq 'IMAPS' || $mailType eq 'IMAP') {
			$log->error("Unable to connect to $mailHost: ". $Net::IMAP::Simple::errstr );
		}elsif($pop3) {
			$log->debug("Logged in successfully");

			my $nm = $pop3->Count();
			$log->debug("Totally $nm messages");
			if($nm<0) {
				$log->error("Some error when retreiving mails");
			}
			for(my $i = $nm;$i > 0; $i--) {
				my $header = $pop3->Head($i);
				my $es = Email::Simple->new($header);
				my $message = {};
				$message->{'From'} = $es->header('From');
				$message->{'To'} = $es->header('To');
				$message->{'Date'} = $es->header('Date');
				my $time = timegm(strptime($message->{'Date'}));
				$message->{'Date'} = Slim::Utils::DateTime::shortDateF($time).' '.Slim::Utils::DateTime::timeF($time);
				$message->{'Subject'} = $es->header('Subject');
				push @$messages,$message;
			}
			$cache->set("$mailHost:$mailType:$mailAccount:$mailFolder-headers",$messages);
			$cache->set("$mailHost:$mailType:$mailAccount:$mailFolder-headers-timestamp",time());
		}else {
			$log->error("Unable to connect or login to $mailHost");
		}
	}
	return $messages;
}

sub getMusicInfoSCRCustomItems {
	my $customFormats = {
		'NEWMAIL' => {
			'cb' => \&handleMusicInfoSCRNewMail,
			'cache' => 5,
		},
	};
	return $customFormats;
}

sub handleMusicInfoSCRNewMail
{
	my $client = shift;
	my $song = shift;
	my $tag = shift;

	$log->debug("Entering handleMusicInfoSCRNewMail");
	my $mails = getMailMessagesWithDefaultCredentials(1);
	if(scalar(@$mails)>0) {
		$log->debug("Exiting handleMusicInfoSCRNewMail with new mail");
		return $client->string("PLUGIN_MAIL_YOUHAVEGOTMAIL");
	}

	$log->debug("Exiting handleMusicInfoSCRNewMail with undef");
	return undef;
}

sub preprocessInformationScreenNewMailsIndication {
	my $client = shift;
	my $screen = shift;

	my $mails = getMailMessagesWithDefaultCredentials(1);
	if(scalar(@$mails)==0) {
		$log->debug("Exit preprocessInformationScreenNewMails with no mails found");
		return 0;
	}
	return 1;
}

sub preprocessInformationScreenNewMails {
	my $client = shift;
	my $screen = shift;

	my $mails = getMailMessagesWithDefaultCredentials(1);
	if(scalar(@$mails)==0) {
		$log->debug("Exit preprocessInformationScreenNewMails with no mails found");
		return 0;
	}

	my @empty = ();
	my $groups = \@empty;
	if(exists $screen->{'items'}->{'item'}) {
		$groups = $screen->{'items'}->{'item'};
		if(ref($groups) ne 'ARRAY') {
			push @empty,$groups;
			$groups = \@empty;
		}
	}
	my $menuGroup = {
		'id' => 'menu',
		'type' => 'simplemenu',
	};
	my @menuItems = ();
	my $index = 1;
	foreach my $mail (@$mails) {
		my $group = {
			'id' => 'item'.$index,
			'type' => 'menuitem',
			'style' => 'item_no_arrow',
		};
		my @items = ();
		my $text = {
			'id' => 'text',
			'type' => 'text',
			'value' => $mail->{'Subject'}."\n".$mail->{'Date'}." ".$client->string("PLUGIN_MAIL_FROM").": ".$mail->{'From'},
		};
		push @items,$text;

		$group->{'item'} = \@items;
		push @menuItems, $group;
		$index++;
	}
	$menuGroup->{'item'} = \@menuItems;
	push @$groups,$menuGroup;
	$screen->{'items'}->{'item'} = $groups;
	$log->debug("Exit preprocessInformationScreenNewMails with ".(scalar(@$mails))." mails found");
	return 1;
}

sub getInformationScreenScreens {
	my $client = shift;
	return Plugins::Mail::Template::Reader::getTemplates($client,'Mail',$PLUGINVERSION,'FileCache/InformationScreen','Screens','xml','template','screen','simple',1);
}

sub getInformationScreenTemplates {
        my $client = shift;
        return Plugins::Mail::Template::Reader::getTemplates($client,'Mail',$PLUGINVERSION,'FileCache/InformationScreen','ScreenTemplates','xml');
}

sub getInformationScreenTemplateData {
        my $client = shift;
        my $templateItem = shift;
        my $parameterValues = shift;
        my $data = Plugins::Mail::Template::Reader::readTemplateData('Mail','ScreenTemplates',$templateItem->{'id'});
        return $data;
}


sub getInformationScreenScreenData {
        my $client = shift;
        my $templateItem = shift;
        my $parameterValues = shift;
        my $data = Plugins::Mail::Template::Reader::readTemplateData('Mail','Screens',$templateItem->{'id'},"xml");
        return $data;
}

sub checkDefaults {
}

# other people call us externally.
*escape   = \&URI::Escape::uri_escape_utf8;

# don't use the external one because it doesn't know about the difference
# between a param and not...
#*unescape = \&URI::Escape::unescape;
sub unescape {
        my $in      = shift;
        my $isParam = shift;

        $in =~ s/\+/ /g if $isParam;
        $in =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;

        return $in;
}

1;

__END__
