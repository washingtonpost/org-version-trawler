package PackageManager::PomXml;

use Modern::Perl '2020';
use Readonly;
use JSON;

## no critic (ProhibitSubroutinePrototypes)
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::Path;

use MIME::Base64 qw/decode_base64/;
use XML::TreePP;
use Carp qw/cluck/;
use PackageManager::Util qw/get_semver_from_string/;

use Data::Dumper;

sub package_manager_details {
  return { name => 'Maven POM',
           re   => qr/^[a-z0-9_\/-]*?(\b|\d)pom(\b|\d)[a-z0-9_-]*?\.xml$/ix
         };
}

sub new ($pkg, $data) {
  my $self = { data => $data };

  return bless $self, $pkg;
}

# Some of the pom.xml functionality allows referencing a parent file.
sub get_parent_path ($self, $parent_path) {
  my $path = Mojo::Path->new("/$self->{data}->{path}")->to_dir;

  my $new_path = $path->merge($parent_path)->canonicalize->to_string;
  if ($new_path !~ m/\.xml/i) {
    $new_path .= '/pom.xml';
  }

  return $new_path;
}

sub get_parent_content ($self, $parent_path) {
  my $content =
      decode_base64(
               $self->{data}->{gh}->repos->get_content(
                 $self->{data}->{repo}->{user}, $self->{data}->{repo}->{name},
                 $parent_path
                   )->{content}
      );

  return $content;
}

sub get_parent_props ($self, $parent_content) {
  my $tree = XML::TreePP->new(utf8_flag => 1)->parse($parent_content);
  return
      exists $tree->{project}->{properties}
      ? $tree->{project}->{properties}
      : {};
}

# Try to support project inheritance!
sub inherit_parent_properties ($self, $pom) {

  # No parent? We're done here.
  if (not exists $pom->{parent}) {
    return exists $pom->{version} ? {'project.version'=>$pom->{version}} : {};
  }

  # Try to load the file.
  my $parentPath
      = exists $pom->{parent}->{relativePath}
      ? $pom->{parent}->{relativePath}
      : "/pom.xml";
  my $props_to_return = $self->get_parent_props(
              $self->get_parent_content($self->get_parent_path($parentPath)));

# It appears that `project.version` is a special property in the pom.xml file.
  # 
  my @precedence = grep { !!$_ } (
    $props_to_return->{'project.version'} || undef,
    $pom->{'version'} || undef,
    $pom->{'parent'}->{'version'} || undef,
    $props_to_return->{'version'} || undef
  );
  $props_to_return->{'project.version'} = $precedence[0];

  return $props_to_return;
}

sub parse($self) {

# If some of this code looks super imperative and dated, that's because it is.
# The Maven::Pom::Xml module was meant for a different task than we're
# using it here, but it'll get the job done.

  $self->{deps} ||= [];

  # Don't bother if we don't have legit data.
  return if (not $self->{data} or not length $self->{data});

  my $success = eval {
    my $pom
        = XML::TreePP->new(utf8_flag => 1)->parse($self->{data}->content)
        ->{project};

    # Since there's a lot of variety in how these files are constructed,
    # We need to be a little flexible.
    my @paths  = qw/dependencyManagement dependencies dependency/;
    my $depref = $pom;
    while (my $next = shift @paths) {
      last if ref $depref eq 'ARRAY';

    # NEW TO PERL?
    # In Perl you can have a reference to pretty much anything.
    # In this chunk I'm trying to traverse a nested structure having
    # a limited set of possible keys. In order to traverse, though, I
    # need to make sure that I'm going into a hashref (a reference to a hash).
    # Using `ref $foo eq 'HASH'` I can determine whether a scalar
    # contains a reference to a hash.
    # END
      if (exists $depref->{$next}) {
        $depref = $depref->{$next};
      }
    }

    # At this point, $depref should point at an arrayref.
    if (ref $depref ne 'ARRAY') {
      say STDERR "I don't know how to parse this pom.xml:"
          . $self->{data}->{path};
      return;
    }

    # Properties don't see so fluid as the dependencies structure.
    my $properties = { %{ $self->inherit_parent_properties($pom) },
                       %{ $pom->{properties} },
                     };

    # Now we're going to construct the internal dependency list.
    for my $raw_dep (@{$depref}) {
      my $name    = $raw_dep->{artifactId};
      my $version = exists $raw_dep->{version} ? $raw_dep->{version} : 'any';

      if (substr($version, 0, 2) eq q?${?) {
## It's common in a pom.xml to have the version be tokenized out into the properties
# section, so now we need to make sure that we parse through those if it's present.
# It's likely imperfect, but "good enough" is what we're going for.
        my $prop_token = substr($version, 2, rindex($version, '}') - 2);
        $version
            = exists $properties->{$prop_token}
            ? $properties->{$prop_token}
            : $version;
        if (ref $version eq 'ARRAY') {
          $version = join ' - ', @{$version};
        }
      }

      push @{ $self->{deps} }, { package => $name, version => $version };
    }

    return 1;
  };
  if (my $err = $@) {

    cluck "Error parsing file: $err";
  }
  if (!$success) {
    cluck "Failed to parse the file, not sure why. $@";
  }

  return;
}

sub has_dependencies($self) {

  # Lazy parse.
  $self->parse()
      if (not exists $self->{deps});

  return scalar @{ $self->{deps} } > 0;
}

sub next_dependency ($self) {

  # Lazy parse.
  $self->parse()
      if (not exists $self->{deps});

  return shift @{ $self->{deps} };
}

1;
