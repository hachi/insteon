package Insteon::Util;

use strict;
use warnings;

use base 'Exporter';

our @EXPORT_OK = qw(&want_name &want_id &get_name &decode_aldb &decode_product_data &decode_engine);

my %device_by_name;
my %device_by_id;

{
    open(my $fh, '<', '/etc/insteon.conf');

    while (my $line = <$fh>) {
        chomp $line;
        if (my ($name, $id) = map { lc($_) } ($line =~ m/^(\w+)\s+([0-9A-F]{6})\b/i)) {
            $device_by_name{$name} = $id;
            $device_by_id{$id} = $name;
        }
    }
}

sub get_name {
    my $input = lc(shift);
    return $device_by_id{$input};
}

sub want_name {
    my $input = lc(shift);
    return $device_by_id{$input} || $input;
}

sub want_id {
    my $input = lc(shift);
    return $device_by_name{$input} || $input;
}

sub decode_product_data {
    my $data = shift;

    # Product Data Response
    # D1: 0x00, D2-D4: Product Key, D5: DevCat, D6: SubCat, D7: Firmware, D8-D14: unspec
    my ($prod_key, $dev_cat, $sub_cat, $firmware) = unpack('xH[6]H[2]H[2]H[2]', $data);

    return bless {
        prod_key   => $prod_key,
        dev_cat    => $dev_cat,
        sub_cat    => $sub_cat,
        firmware   => $firmware,
    }, "Insteon::Util::ProductData";
}

sub decode_engine {
    my $data = shift;

    return bless {
        version => $data,
    }, "Insteon::Util::Engine";
}

sub decode_aldb {
    my $input = shift;

    die "Wrong DB entry length" unless length($input) == 8;

    my ($control, $group, $address, $d1, $d2, $d3) = unpack('CH[2]H[6]H[2]H[2]H[2]', $input);

    return bless {
        group   => $group,
        address => $address,
        control => $control,
        data    => [ $d1, $d2, $d3 ],
    }, "Insteon::Util::ALDBEntry";
}

package Insteon::Util::ProductData;

use overload '""' => 'as_string';

sub as_string {
    my $self = shift;
    my $prod_key   = $self->{prod_key};
    my $dev_cat    = $self->{dev_cat};
    my $sub_cat    = $self->{sub_cat};
    my $firmware   = $self->{firmware};
    return "Product Data PK: $prod_key Category: $dev_cat/$sub_cat Firmware: $firmware";
}

sub dev_cat {
    my $self = shift;
    return $self->{dev_cat};
}

sub sub_cat {
    my $self = shift;
    return $self->{dev_cat};
}

sub is_general {
    my $self = shift;
    return $self->dev_cat == "00" ? 1 : 0;
}

sub is_lighting_dimmable {
    my $self = shift;
    return $self->dev_cat == "01" ? 1 : 0;
}

sub is_lighting_switched {
    my $self = shift;
    return $self->dev_cat == "02" ? 1 : 0;
}

sub is_lighting {
    my $self = shift;
    return $self->is_lighting_dimmable || $self->is_lighting_switched;
}

package Insteon::Util::Engine;

use overload '""' => 'as_string';

sub as_string {
    my $self = shift;

    my $version = $self->{version};
    my $verstr = { '00' => 'i1', '01' => 'i2', '02' => 'i2cs', 'ff' => 'unlinked' }->{$version};

    return sprintf "%s(%s)", $version, $verstr || 'unknown';
}

sub version {
    my $self = shift;

    return $self->{version};
}

sub is_i1 {
    my $self = shift;
    return $self->version == '00' ? 1 : 0;
}

sub is_i2 {
    my $self = shift;
    return $self->version == '01' ? 1 : 0;
}

sub is_i2cs {
    my $self = shift;
    return $self->version == '02' ? 1 : 0;
}

sub is_unlinked {
    my $self = shift;
    return $self->version == 'FF' ? 1 : 0;
}

package Insteon::Util::ALDBEntry;

use overload '""' => 'as_string';

sub as_string {
    my $self = shift;

    my $group   = $self->{group};
    my $address = $self->{address};
    my $control = $self->{control};
    my $data    = $self->{data};

    my ($d1, $d2, $d3) = @$data;

    my @output;

    if ($control & 128) {
        push @output, "In Use";
    }

    push @output, ($control & 64) ? "Master" : "Slave";

    if ($control & 2) {
        push @output, "Next";
    }

    if (my $name = Insteon::Util::get_name($address)) {
        $address .= "($name)";
    }

    return "Group: $group Address: $address Control: " . $control . " [" . join(',', @output) . "] $d1 $d2 $d3";
}

sub device_address {
    my $self = shift;
    return $self->{address};
}

sub device_name {
    my $self = shift;
    return Insteon::Util::get_name($self->{address});
}

sub in_use {
    my $self = shift;
    return ($self->{control} & 128) ? 1 : 0;
}

sub master {
    my $self = shift;
    return ($self->{control} & 64) ? 1 : 0;
}

sub slave {
    my $self = shift;
    return ($self->{control} & 64) ? 0 : 1;
}

sub next {
    my $self = shift;
    return ($self->{control} & 2) ? 1 : 0;
}

sub last {
    my $self = shift;
    return ($self->{control} & 2) ? 0 : 1;
}

1;
