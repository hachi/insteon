package Insteon::Device;

use strict;
use warnings;

use Scalar::Util qw(weaken);
use Insteon::Util qw(decode_aldb);

our %devices;

sub get {
    my $class = shift;
    my $plm = shift;
    my $address = shift;

    return $devices{$address} if $devices{$address};

    my $self = bless {
        address => $address,
        plm     => $plm,
        locks   => {},
        standard_handlers => [],
        extended_handlers => [],
    }, (ref $class || $class);

    $devices{$address} = $self;

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
    my $callback = shift;

    return if $self->{locks}->{get_product_data};

    push @{$self->{'extended_handlers'}}, sub {
        my ($from, $to, $flag, $command, $data) = @_;
        if ($command eq '0300') {
            delete $self->{locks}->{get_product_data};
            # Product Data Response
            # D1: 0x00, D2-D4: Product Key, D5: DevCat, D6: SubCat, D7: Firmware, D8-D14: unspec
            my ($prod_key, $dev_cat, $sub_cat, $firmware) = unpack('xH[6]H[2]H[2]H[2]', $data);
            $callback->($self, "Product Data PK: $prod_key Category: $dev_cat/$sub_cat Firmware: $firmware");
            return 1;
        }
    };

    $self->_standard(qw(0300), sub {
        $self->{locks}->{get_product_data} = $self->{plm}->_loop_token();
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
    my $callback = shift;

    return if $self->{locks}->{get_engine};

    push @{$self->{'standard_handlers'}}, sub {
        my ($from, $to, $flag, $command) = @_;

        if ($command =~ m/^0d([0-9a-f]{2})/i) {
            my $version = lc($1);
            delete $self->{locks}->{get_engine};
            my $verstr = { '00' => 'i1', '01' => 'i2', '02' => 'i2cs', 'ff' => 'unlinked' }->{$version};
            $callback->($self, ($verstr || 'unknown'), $version);
            return 1;
        }
        return 0;
    };

    $self->_standard(qw(0D00), sub {
        $self->{locks}->{get_engine} = $self->{plm}->_loop_token();
    });
}

sub ping {
    my $self = shift;
    $self->_standard(qw(0F00), sub {
        $self->{locks}->{ping} = $self->{plm}->_loop_token();
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

    die if $self->{locks}->{read_aldb};

    my @records;

    push @{$self->{'extended_handlers'}}, sub {
        my ($from, $to, $flag, $command, $data) = @_;

        if ($command eq '2f00') {
            # All Link DB
            my ($rrw, $address, $l, $record) = unpack('xCH[4]Ca[8]x', $data);
            if ($rrw == 1) {
                my $record = "ALDB($address) " . decode_aldb($record);
                push @records, $record;
                # Advance timeout if we have one

                unless ($record =~ m/\bNext\b/) {
                    delete $self->{locks}->{read_aldb};
                    $callback->($self, join("\n", @records));
                    return 1;
                }
            }
        }
    };

    $self->_extended(qw(2f00 0000000000000000000000000000), sub {
        $self->{locks}->{read_aldb} = $self->{plm}->_loop_token();
    });
}

sub _receive_standard {
    my $self = shift;
    my ($from, $to, $flag, $command) = @_;

    foreach my $handler (@{$self->{standard_handlers}}) {
        return 1 if $handler->(@_);
    }

    return 0;
}

sub _receive_extended {
    my $self = shift;
    my ($from, $to, $flag, $command, $data) = @_;

    foreach my $handler (@{$self->{extended_handlers}}) {
        # FIXME NEED TO REMOVE A HANDLER IF IT CATCHES A MESSAGE
        return 1 if $handler->(@_);
    }

    if ($command eq '2e00') {
        my ($bg, $verb, $x10h, $x10u) = unpack('H[2]H[2]xxH[2]H[2]', $data);
    }

    return 1;
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
