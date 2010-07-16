
use strict;
use warnings;

use Module::Build 0.3601;


my %module_build_args = (
  'build_requires' => {
    'Module::Build' => '0.3601'
  },
  'configure_requires' => {
    'Module::Build' => '0.3601'
  },
  'dist_abstract' => 'The Standard Perl 6 Grammar',
  'dist_author' => [
    'Larry Wall <larry@wall.org>',
    'Stefan O\'Rear',
    'Pawel Murias <pawelmurias@gmail.com>'
  ],
  'dist_name' => 'STD',
  'dist_version' => '0.01',
  'license' => 'artistic_2',
  'module_name' => 'STD',
  'recommends' => {},
  'recursive_test_files' => 1,
  'requires' => {},
  'script_files' => [],
  'share_dir' => {
    'dist' => 'data'
  }
);


my $build = Module::Build->new(%module_build_args);

$build->create_build_script;
