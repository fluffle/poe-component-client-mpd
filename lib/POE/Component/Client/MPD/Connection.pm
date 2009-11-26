use 5.010;
use strict;
use warnings;

package POE::Component::Client::MPD::Connection;
# ABSTRACT: module handling the tcp connection with mpd

use Audio::MPD::Common::Item;
use POE;
use POE::Component::Client::TCP;
use Readonly;

use POE::Component::Client::MPD::Message; # for exported constants


# -- attributes

=attr host

The hostname of the mpd server. Mandatory, no default.

=attr port

The port of the mpd server. Mandatory, no default.

=attr id

The POE session id of the peer to dialog with. Mandatory, no default.

=attr max_retries

How much time to attempt reconnection before giving up. Defaults to 5.

=attr retry_wait

How much time to wait (in seconds) before attempting socket
reconnection. Defaults to 2.

=cut


# -- public methods

=method my $id = POE::Component::Client::MPD::Connection->new( \%params );

This method will create a L<POE::Component::Client::TCP> session
responsible for low-level communication with mpd.

It will return the poe id of the session newly created.

=cut

sub new {
    my ($type, $args) = @_;

    # connect to mpd server.
    my $id = POE::Component::Client::TCP->new(
        RemoteAddress => $args->{host},
        RemotePort    => $args->{port},
        Filter        => 'POE::Filter::Line',
        Args          => [ $args ],
        Alias         => '_mpd_conn',

        ServerError  => sub { }, # quiet errors
        Started      => \&_Started,
        Connected    => \&_Connected,
        ConnectError => \&_ConnectError,
        Disconnected => \&_Disconnected,
        ServerInput  => \&_ServerInput,

        InlineStates => {
            send       => \&send,         # send data
            disconnect => \&disconnect,   # force quit
        },
    );

    return $id;
}



# -- public events

=event disconnect( )

Request the pococm-connection to be shutdown. This does B<not> shut down
the MPD server. No argument.

=cut

sub disconnect {
    $_[HEAP]->{auto_reconnect} = 0;    # no more auto-reconnect.
    $_[KERNEL]->yield( 'shutdown' );   # shutdown socket.
}


=event send( $message )

Request pococm-conn to send the C<$message> over the wires. Note that
this request is a L<POE::Component::Client::MPD::Message> object
properly filled up, and that the C<_commands()> attribute should B<not>
be newline terminated.

=cut

sub send {
    my ($h, $msg) = @_[HEAP, ARG0];
    # $_[HEAP]->{server} is a reserved slot of pococ-tcp.
    $h->{server}->put( @{ $msg->_commands } );
    push @{ $h->{fifo} }, $msg;
}


# -- private events

#
# event: Started($id)
#
# Called whenever the session is started, but before the tcp connection is
# established. Receives the session $id of the poe-session that will be our
# peer during the life of this session.
#
sub _Started {
    my ($h, $args) = @_[HEAP, ARG0];

    # storing params
    $h->{session}     = $args->{id};                # poe-session peer
    $h->{max_retries} = $args->{max_retries} // 5;  # max retries before giving up
    $h->{retry_wait}  = $args->{retry_wait}  // 2;  # sleep time before retry

    # setting session vars
    $h->{auto_reconnect} = 1;                   # on-disconnect policy
    $h->{retries_left}   = $h->{max_retries};   # how much chances is there still?
}


#
# event: Connected()
#
# Called whenever the tcp connection is established.
#
sub _Connected {
    my $h = $_[HEAP];
    $h->{fifo}         = [];                 # reset current messages
    $h->{incoming}     = [];                 # reset incoming data
    $h->{is_mpd}       = 0;                  # is remote server a mpd sever?
    $h->{retries_left} = $h->{max_retries};  # reset connection retries count
}


#
# event: ConnectError($syscall, $errno, $errstr)
#
# Called whenever the tcp connection fails to be established. Generally
# due to mpd server not started, or wrong host / port, etc. Receives
# the $syscall that failed, as well as $errno and $errstr.
#
sub _ConnectError {
    my ($k, $h, $syscall, $errno, $errstr) = @_[KERNEL, HEAP, ARG0, ARG1, ARG2];
    return unless $h->{auto_reconnect};

    # check if this is the last allowed error.
    $h->{retries_left}--;
    my ($event, $msg);
    if ( $h->{retries_left} > 0 ) {
        # nope, we can reconnect
        $event = 'mpd_connect_error_retriable';
        $msg   = '';

        # auto-reconnect in $retry_wait seconds
        $k->delay_add('reconnect' => $h->{retry_wait});

    } else {
        # yup, it was our last chance.
        $event = 'mpd_connect_error_fatal';
        $msg   = 'Too many failed attempts! error was: ';
    }

    # signal that there was a problem during connection
    my $error = $msg . "$syscall: ($errno) $errstr";
    $k->post( $h->{session}, $event, $error );
}


#
# event: Disconnected()
#
# Called whenever the tcp connection is broken / finished.
#
sub _Disconnected {
    my ($k, $h) = @_[KERNEL, HEAP];

    # signal that we're disconnected
    $k->post($h->{session}, 'mpd_disconnected');

    # auto-reconnect in $retry_wait seconds
    return unless $h->{auto_reconnect};
    $k->delay_add('reconnect' => $h->{retry_wait});
}


#
# event: ServerInput($input)
#
# Called whenever the tcp peer sends data over the wires, with the $input
# transmitted given as param.
#
sub _ServerInput {
    my ($k, $h, $input) = @_[KERNEL, HEAP, ARG0];

    # did we check we were talking to a mpd server?
    if ( not $h->{is_mpd} ) {
        _got_first_input_line($k, $h, $input);
        return;
    }

    # table of dispatch: check input against regex, and process it.
    given ($input) {
        when ( /^OK$/ )      { _got_data_eot($k, $h);     }
        when ( /^ACK (.*)/ ) { _got_error($k, $h, $1);    }
        default              { _got_data($k, $h, $input); }
    }
}


# -- private subs

#
# _got_data($kernel, $heap, $input);
#
# called when receiving another piece of data.
#
sub _got_data {
    my ($k, $h, $input) = @_;

    # regular data, to be cooked (if needed) and stored.
    my $msg = $h->{fifo}[0];

    given ($msg->_cooking) {
        when ('raw') {
            # nothing to do, just push the data.
            push @{ $h->{incoming} }, $input;
        }

        when ('as_items') {
            # Lots of POCOCM methods are sending commands and then parse the
            # output to build an amc-item.
            my ($k,$v) = split /:\s+/, $input, 2;
            $k = lc $k;
            $k =~ s/-/_/;

            if ( $k eq 'file' || $k eq 'directory' || $k eq 'playlist' ) {
                # build a new amc-item
                my $item = Audio::MPD::Common::Item->new( $k => $v );
                push @{ $h->{incoming} }, $item;
            }

            # just complete the current amc-item
            $h->{incoming}[-1]->$k($v);
        }

        when ('as_kv') {
            # Lots of POCOCM methods are sending commands and then parse the
            # output to get a list of key / value (with the colon ":" acting
            # as separator).
            my @data = split(/:\s+/, $input, 2);
            push @{ $h->{incoming} }, @data;
        }

        when ('strip_first') {
            # Lots of POCOCM methods are sending commands and then parse the
            # output to remove the first field (with the colon ":" acting as
            # separator).
            $input = ( split(/:\s+/, $input, 2) )[1];
            push @{ $h->{incoming} }, $input;
        }
    }
}


#
# _got_data_eot($kernel, $heap)
#
# called when the stream of data is finished. used to send the received
# data.
#
sub _got_data_eot {
    my ($k, $h) = @_;
    my $session = $h->{session};
    my $msg     = shift @{ $h->{fifo} };     # remove completed msg
    $msg->_set_data($h->{incoming});         # complete message with data
    $msg->set_status(1);                     # success
    $k->post($session, 'mpd_data', $msg);    # signal poe session
    $h->{incoming} = [];                     # reset incoming data
}


#
# _got_error($kernel, $heap, $errstr);
#
# called when the mpd server reports an error. used to report the error
# to the pococm.
#
sub _got_error {
    my ($k, $h, $errstr) = @_;

    my $session = $h->{session};
    my $msg     = shift @{ $h->{fifo} };
    $k->post($session, 'mpd_error', $msg, $errstr);
}


#
# _got_first_input_line($kernel, $heap, $input);
#
# called when the mpd server fires the first line. used to check whether
# we are talking to a regular mpd server.
#
sub _got_first_input_line {
    my ($k, $h, $input) = @_;

    if ( $input =~ /^OK MPD (.*)$/ ) {
        $h->{is_mpd} = 1;  # remote server *is* a mpd sever
        $k->post($h->{session}, 'mpd_connected', $1);
    } else {
        # oops, it appears that it's not a mpd server...
        $k->post(
            $h->{session}, 'mpd_connect_error_fatal',
            "Not a mpd server - welcome string was: '$input'",
        );
    }
}


1;
__END__


=head1 DESCRIPTION

This module will spawn a poe session responsible for low-level
communication with mpd. It is written as a
L<POE::Component::Client::TCP>, which is taking care of
everything needed.

Note that you're B<not> supposed to use this class directly: it's one of
the helper class for L<POE::Component::Client::MPD>.



=head1 PUBLIC EVENTS FIRED

The following events are fired from the spawned session.


=head2 mpd_connected( $version )

Fired when the session is connected to a mpd server. This event isn't
fired when the socket connection takes place, but when the session has
checked that remote peer is a real mpd server. C<$version> is the
advertised mpd server version.


=head2 mpd_connect_error_fatal( $errstr )

Fired when the session encounters a fatal error. This happens either
when the session is connected to a server which happens to be something
else than a mpd server, or if there was more than C<max_retries> (see
C<spawn()> params) connection retries in a row. C<$errstr> will contain
the problem encountered. No retries will be done.


=head2 mpd_connect_error_retriable( $errstr )

Fired when the session has troubles connecting to the server. C<$errstr>
will point the faulty syscall that failed. Re-connection will be tried
after C<$retry_wait> seconds (see C<spawn()> params).


=head2 mpd_data( $msg )

Fired when C<$msg> has been sent over the wires, and mpd server has
answered with success. The actual output should be looked up in
C<$msg->_data>.


=head2 mpd_disconnected( )

Fired when the socket has been disconnected for whatever reason. Note
that this event is B<not> fired in the case of a programmed shutdown
(see C<disconnect()> event above). A reconnection will be automatically
re-tried after C<$retry_wait> (see C<spawn()> params).


=head2 mpd_error( $msg, $errstr )

Fired when C<$msg> has been sent over the wires, and mpd server has
answered with the error message C<$errstr>.


