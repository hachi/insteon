package Insteon::Util;

use strict;
use warnings;

use base 'Exporter';

our @EXPORT_OK = qw(&want_name &want_id &get_name &decode_aldb);

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

sub decode_aldb {
    my $input = shift;

    die "Wrong DB entry length" unless length($input) == 8;

    my @output;

    my ($control, $group, $address, $d1, $d2, $d3) = unpack('CH[2]H[6]H[2]H[2]H[2]', $input);

    if ($control & 128) {
        push @output, "In Use";
    }

    push @output, ($control & 64) ? "Master" : "Slave";

    if ($control & 2) {
        push @output, "Next";
    }

    if (my $name = get_name($address)) {
        $address .= "($name)";
    }

    return "Group: $group Address: $address Control: " . $control . " [" . join(',', @output) . "] $d1 $d2 $d3";
}

1;
