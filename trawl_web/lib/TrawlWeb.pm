package TrawlWeb;
use Mojo::Base 'Mojolicious';

use FindBin qw/$Bin/;
use lib qq{$Bin/../lib};
use TrawlWeb::Controller::Trawl;

# This method will run once at server start
sub startup {
  my $self = shift;

  # Load configuration from hash returned by config file
  my $config = $self->plugin('Config');

  # Load the TagHelpers...
  $self->plugin('DefaultHelpers');
  $self->plugin('TagHelpers');

  # Load the Charts plugin
  $self->plugin('TrawlWeb::Plugin::Charts', {});
  $self->defaults(breadcrumbs => []);

  # Configure the application
  $self->secrets($config->{secrets});

  # Router
  my $r = $self->routes;

  # Normal route to controller
  $r->get('/')->to('home#welcome');
  $r->get('/health')->to('home#health');
  $r->get('/package_manager/:pkg_mgr_name')->to('home#package_manager');
  $r->get('/package_manager/:pkg_mgr_name/package_name/:pkg_name')
    ->to('home#package_name');
  $r->get(
    '/package_manager/:pkg_mgr_name/package_name/:pkg_name/version/:pkg_version'
  )->to('home#package_version');
  $r->get('/trawl')->to('trawl#run');
  $r->post('/search/repo')->to('search#repo');

  return;
}

1;
