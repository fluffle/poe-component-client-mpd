#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#
#

package POE::Component::Client::MPD::Test;

use strict;
use warnings;

use FindBin     qw[ $Bin ];
use POE         qw[ Component::Client::MPD ];
use Readonly;
use Test::More;


use base qw[ Exporter ];
our @EXPORT = qw[ customize_test_mpd_configuration start_test_mpd stop_test_mpd ];

#our ($VERSION) = '$Rev: 5727 $' =~ /(\d+)/;


Readonly my $ALIAS    => 'tester';
Readonly my $TEMPLATE => "$Bin/mpd-test/mpd.conf.template";
Readonly my $CONFIG   => "$Bin/mpd-test/mpd.conf";


{ # this will be run when pococm::Test will be use-d.
    my $restart = 0;
    my $stopit  = 0;

    customize_test_mpd_configuration();
    $restart = _stop_user_mpd_if_needed();
    $stopit  = start_test_mpd();

    # fake mpd has been started successfully, plan the tests.
    plan tests => $::nbtests;

    # fire pococm + create session to follow the tests.
    POE::Component::Client::MPD->spawn( { alias => 'mpd' } );
    POE::Session->create(
        inline_states => {
            _start     => \&_onpriv_start,
            mpd_result => \&_onpub_mpd_result,
            next_test  => \&_onpub_next_test,
        }
    );
    POE::Kernel->run;
    exit;

    END {
        stop_test_mpd() if $stopit;
        return unless $restart;       # no need to restart
        system 'mpd 2>/dev/null';     # restart user mpd
        sleep 1;                      # wait 1 second to let mpd start.
    }
}


#--
# public subs

#
# customize_test_mpd_configuration( [$port] )
#
# Create a fake mpd configuration file, based on the file mpd.conf.template
# located in t/mpd-test. The string PWD will be replaced by the real path -
# ie, where the tarball has been untarred. The string PORT will be replaced
# by $port if specified, 6600 otherwise (MPD default).
#
sub customize_test_mpd_configuration {
    my ($port) = @_;
    $port ||= 6600;

    # open template and config.
    open my $in,  '<',  $TEMPLATE or die "can't open [$TEMPLATE]: $!\n";
    open my $out, '>',  $CONFIG   or die "can't open [$CONFIG]: $!\n";

    # replace string and fill in config file.
    while ( defined( my $line = <$in> ) ) {
        $line =~ s!PWD!$Bin/mpd-test!;
        $line =~ s!PORT!$port!;
        print $out $line;
    }

    # clean up.
    close $in;
    close $out;

    # create a fake mpd db.
    system( "mpd --create-db $CONFIG >/dev/null 2>&1" ) == 0
        or die "could not create fake mpd database: $?\n";
}


#
# start_test_mpd()
#
# Start the fake mpd, and die if there were any error.
#
sub start_test_mpd {
    my $output = qx[mpd $CONFIG 2>&1];
    die "could not start fake mpd: $output\n" if $output;
    sleep 1;   # wait 1 second to let mpd start.
    return 1;
}


#
# stop_test_mpd()
#
# Kill the fake mpd.
#
sub stop_test_mpd {
    system "mpd --kill $CONFIG 2>/dev/null";
    sleep 1;   # wait 1 second to free output device.
    unlink "$Bin/mpd-test/state", "$Bin/mpd-test/music.db";
}


#--
# private subs


#
# my $was_running = _stop_user_mpd_if_needed()
#
# This sub will check if mpd is currently running. If it is, force it to
# a full stop (unless MPD_TEST_OVERRIDE is not set).
#
# In any case, it will return a boolean stating whether mpd was running
# before forcing stop.
#
sub _stop_user_mpd_if_needed {
    # check if mpd is running.
    my $is_running = grep { /mpd$/ } qx[ ps -e ];

    return 0 unless $is_running; # mpd does not run - nothing to do.

    # check force stop.
    die "mpd is running\n" unless $ENV{MPD_TEST_OVERRIDE};
    system( 'mpd --kill 2>/dev/null') == 0 or die "can't stop user mpd: $?\n";
    sleep 1;  # wait 1 second to free output device
    return 1;
}


#--
# private events


#
# event: _start()
#
# Called when the poe session has started.
#
sub _onpriv_start {
    my $k = $_[KERNEL];
    $k->alias_set($ALIAS);           # increment refcount
    $k->yield( 'next_test' );       # launch the first test.
}


#--
# public events


#
# event: next_test()
#
# Called to schedule the next test.
#
sub _onpub_next_test {
    my $k = $_[KERNEL];

    if ( scalar @::tests == 0 ) { # no more tests.
        $k->alias_remove($ALIAS);
        $k->post( 'mpd', 'disconnect' );
        return;
    }

    # post next event.
    my $event = $::tests[0][0];
    my $args  = $::tests[0][1];
    $k->post( 'mpd', $event, @$args );
}


#
# event: mpd_result( $answer )
#
# Called when mpd talks back, with $answer as a pococm-answer param.
#
sub _onpub_mpd_result {
    $::tests[0][2]->( $_[ARG0] );      # check if everything went fine
    shift @::tests;                    # remove test being played
    $_[KERNEL]->yield( 'next_test' );  # call next test
}


1;

__END__

=head1 NAME

POE::Component::Client::MPD::Test - automate launching of fake mdp for testing purposes


=head1 SYNOPSIS

    use POE::Component::Client::MPD::Test; # die if error
    [...]
    stop_fake_mpd();


=head1 DESCRIPTION

=head2 General usage

This module will try to launch a new mpd server for testing purposes. This
mpd server will then be used during POE::Component::Client::MPD tests.

In order to achieve this, the module will create a fake mpd.conf file with
the correct pathes (ie, where you untarred the module tarball). It will then
check if some mpd server is already running, and stop it if the
MPD_TEST_OVERRIDE environment variable is true (die otherwise). Last it will
run the test mpd with its newly created configuration file.

Everything described above is done automatically when the module is C<use>-d.


Once the tests are run, the mpd server will be shut down, and the original
one will be relaunched (if there was one).

Note that the test mpd will listen to C<localhost>, so you are on the safe
side. Note also that the test suite comes with its own ogg files - and yes,
we can redistribute them since it's only some random voice recordings :-)


=head2 Advanced usage

In case you want more control on the test mpd server, you can use the
following public methods:

=over 4

=item start_test_mpd()

Start the fake mpd, and die if there were any error.

=item stop_test_mpd()

Kill the fake mpd.

=item customize_test_mpd_configuration( [$port] )

Create a fake mpd configuration file, based on the file mpd.conf.template
located in t/mpd-test. The string PWD will be replaced by the real path -
ie, where the tarball has been untarred. The string PORT will be replaced
by $port if specified, 6600 otherwise (MPD default).

=back

This might be useful when trying to test connections with mpd server.


=head1 AUTHOR

Jerome Quelin, C<< <jquelin at cpan.org> >>


=head1 COPYRIGHT AND LICENSE

Copyright (c) 2007 Jerome Quelin

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

=cut
