package Insteon::Device;

use strict;
use warnings;

use Scalar::Util qw(weaken);

our %devices;

sub get {
    my $class = shift;
    my $plm = shift;
    my $address = shift;

    return $devices{$address} if $devices{$address};

    my $self = bless {
        address => $address,
        plm     => $plm,
    }, (ref $class || $class);

    weaken($devices{$address} = $self);

    return $self;
}

sub _standard {
    my $self = shift;
    return $self->{plm}->send_insteon_standard($self->{address}, @_);
}

sub _extended {
    my $self = shift;
    return $self->{plm}->send_insteon_extended($self->{address}, @_);
}

sub get_product_data {
    my $self = shift;
    $self->_standard(qw(0300), sub {
    });
}

sub get_device_string {
    my $self = shift;
    $self->_standard(qw(0302), sub {
    });
}

sub set_device_string {
    my $self = shift;
    my $string = shift;
    $self->_extended(qw(0303), $string, sub {
    });
}

sub start_link {
    my $self = shift;
    my $group = shift;

    my $group_hex = unpack("H2", $group);

    $self->_standard(qw(09) . $group_hex, sub {
    });
}

sub start_unlink {
    my $self = shift;
    my $group = shift;

    my $group_hex = unpack("H2", $group);

    $self->_standard(qw(0A) . $group_hex, sub {
    });
}

sub get_engine {
    my $self = shift;

    $self->_standard(qw(0D00), sub {
    });
}

sub ping {
    my $self = shift;
    $self->_standard(qw(0F00), sub {
    });
}

sub get_id {
    my $self = shift;
    $self->_standard(qw(1000), sub {
    });
}

sub go_on {
    my $self = shift;
    my $level = shift;

    my $level_hex = unpack("H2", $level);

    $self->_standard(qw(11) . $level_hex, sub {
    });
}

sub go_on_fast {
    my $self = shift;
    my $level = shift;

    my $level_hex = unpack("H2", $level);

    $self->_standard(qw(12) . $level_hex, sub {
    });
}

sub go_off {
    my $self = shift;
    $self->_standard(qw(1300), sub {
    });
}

sub go_off_fast {
    my $self = shift;
    $self->_standard(qw(1400), sub {
    });
}

sub go_bright {
    my $self = shift;
    $self->_standard(qw(1500), sub {
    });
}

sub go_dim {
    my $self = shift;
    $self->_standard(qw(1600), sub {
    });
}

#sub go_change {
#    my $self = shift;
#    my $direction = shift;
#    $self->_standard(qw(1700), sub {
#    });
#}

sub go_stop {
    my $self = shift;
    $self->_standard(qw(1800), sub {
    });
}

sub get_status {
    my $self = shift;
    $self->_standard(qw(1900), sub {
    });
}

sub get_operating_flags {
    my $self = shift;
    $self->_standard(qw(1F00), sub {
    });
}

#sub set_operating_flags {
#    my $self = shift;
#    my $flags = shift;
#    $self->_standard(qw(2000), sub {
#    });
#}

#sub go_on_instant {
#    my $self = shift;
#    my $level = shift;
#    $self->_standard(qw(2100), sub {
#    });
#}

# 0x28 to 0x2D are old peek/poke

#sub go_on_ramp {
#    my $self = shift;
#    my $rate = shift;
#    my $level = shift;
#    $self->_standard(qw(2E00), sub {
#    });
#}

#sub go_off_ramp {
#    my $self = shift;
#    my $rate = shift;
#    $self->_standard(qw(2F00), sub {
#    });
#}

sub beep {
    my $self = shift;
#    my $duration = shift;
    $self->_standard(qw(3001), sub {
    });
}

sub read_aldb {
    my $self = shift;
    my $callback = shift;

    die if $self->{aldb_lock};
    $self->{aldb_lock} = $self->{plm}->_loop_token();

    my @records;

    my $listener = sub {
        push @records, @_;
        unless ($records[-1] =~ m/\bNext\b/) {
            delete $self->{aldb_lock};
            delete $self->{aldb_listener};
            $callback->(@records);
            return;
        }
        # Advance timeout if we have one
    };

    $self->_extended(qw(2f00 0000000000000000000000000000), sub {
        $self->{aldb_listener} = $listener;
    });
}

sub _receive_aldb {
    my $self = shift;
    my $record = shift;
    if (my $listener = $self->{aldb_listener}) {
        $listener->($record);
    } else {
        print "Unsolicited ALDB record: " . $record;
    }
}

# Write ALDB D2 0x02, D3-D4 address, D5 number of bytes (0x01-0x08), D6-D13 data to write.
# ALDB(0fbf) Group: 01 Address: nnnnnn(outside_drive) Control: 226 [In Use,Master,Next] 05 1c 01
#$plm->send_insteon_extended(qw(garage 2f00 00020FBF08000000000000000000));

# Extended settings get
#$plm->send_insteon_extended(qw(outside_garage 2E00 0000000000000000000000000000));
#$plm->send_insteon_extended(qw(front_light 2E00 0000000000000000000000000000));

# Extended settings set LED global LED brightness
#$plm->send_insteon_extended(qw(outside_garage 2E00 00077F0000000000000000000000));
#$plm->send_insteon_extended(qw(front_light 2E00 0007110000000000000000000000));

1;
