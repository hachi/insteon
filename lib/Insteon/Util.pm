package Insteon::Util;

use strict;
use warnings;

use base 'Exporter';

our @EXPORT_OK = qw(&want_name &want_id &get_name);

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

1;
