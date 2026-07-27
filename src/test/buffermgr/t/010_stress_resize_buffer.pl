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

if (!$ENV{PG_TEST_EXTRA} || $ENV{PG_TEST_EXTRA} !~ /\bbufmgr_stress\b/)
{
	plan skip_all => "bufmgr_stress not enabled in PG_TEST_EXTRA";
}

# A mix of small and large sizes exercises the resize logic in a variety
# of scenarios.
my @buffer_sizes =
  (128, 28, 16 * 1024, 32 * 1024, 1024, 512, 16, 24, 256, 128 * 1024);

my $stress = StressUtil->new(
	buffer_sizes => \@buffer_sizes,
	application_name => 'pgbench_buffer_resize_test',
	pgbench_clients => 10,
	pgbench_scale => 10,
	pgbench_duration => 120,);

$stress->setup;

$stress->run;

done_testing();
