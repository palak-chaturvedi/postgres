# Copyright (c) 2025-2026, PostgreSQL Global Development Group
#
# Minimal stress test: resize shared_buffers repeatedly against regular pgbench
# workload.

use strict;
use warnings;
use FindBin;
use lib $FindBin::RealBin;
use Test::More;
use StressUtil;

# A mix of small and large sizes exercises the resize logic in a variety
# of scenarios.
my @buffer_sizes = (
	128, 28, 16 * 1024, 32 * 1024, 1024, 512, 16, 24, 256, 128 * 1024);

my $stress = StressUtil->new(
	buffer_sizes => \@buffer_sizes,
	application_name => 'pgbench_buffer_resize_test',
	pgbench_clients => 10,
	pgbench_scale => 10,
	pgbench_duration => 120,
);

$stress->setup;

# per_transaction forces pgbench to open a new connection per
# transaction, increasing the chance of a new backend attaching while a
# resize is in flight.
$stress->run(client_mode => 'per_transaction');

done_testing();
