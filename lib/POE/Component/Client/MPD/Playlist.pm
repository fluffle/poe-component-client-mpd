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

package POE::Component::Client::MPD::Playlist;

use strict;
use warnings;

use POE;


sub new { return bless {}, shift; }


#
# pl:add $path, $path, ...
#
# Add the songs identified by $path (relative to MPD's music directory) to
# the current playlist.
# No return event.
#
sub _onpub_add {
    my @pathes   = @_[ARG0 .. $#_];    # args of the poe event
    my @commands = (                   # build the commands
        'command_list_begin',
        map( qq[add "$_"], @pathes ),
        'command_list_end',
    );

    # send the commands to mpd.
    my $args = {
        from     => $_[SENDER]->ID,
        state    => $_[STATE],
        commands => \@commands
    };
    $_[KERNEL]->yield( '_send', $args );
}


#
# pl:delete $number, $number, ...
#
# Remove song $number (starting from 0) from the current playlist.
# No return event.
#
sub _onpub_delete {
    my @numbers  = @_[ARG0 .. $#_];    # args of the poe event
    my @commands = (                   # build the commands
        'command_list_begin',
        map( qq[delete $_], reverse sort {$a<=>$b} @numbers ),
        'command_list_end',
    );

    # send the commands to mpd.
    my $args = {
        from     => $_[SENDER]->ID,
        state    => $_[STATE],
        commands => \@commands
    };
    $_[KERNEL]->yield( '_send', $args );
}


1;

__END__