use Module::Build;
use strict;

my $build = Module::Build->new(
  create_makefile_pl => 'traditional',
  license     => 'perl',
  module_name => 'Net::DAV::Server',
  requires    => {
    'Class::Accessor::Fast' => 0,
    'Encode' => 0,
    'File::Slurp' => 0,
    'File::Find::Rule::Filesys::Virtual' => 0,
    'HTTP::Date' => 0,
    'HTTP::Headers' => 0,
    'HTTP::Response' => 0,
    'HTTP::Request' => 0,
    'Test::More' => 0,
    'URI' => 0,
    'URI::Escape' => 0,
    'XML::LibXML' => 0,
},
);
$build->create_build_script;
