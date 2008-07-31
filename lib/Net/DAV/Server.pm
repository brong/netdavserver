package Net::DAV::Server;
use strict;
use warnings;
use File::Slurp;
use Encode;
use File::Find::Rule::Filesys::Virtual;
use HTTP::Date qw(time2str time2isoz);
use HTTP::Headers;
use HTTP::Response;
use HTTP::Request;
use File::Spec;
use URI;
use URI::Escape;
use XML::LibXML;
use base 'Class::Accessor::Fast';
__PACKAGE__->mk_accessors(qw(filesys));
our $VERSION = '1.29';

our %implemented = (
  options  => 1,
  put      => 1,
  get      => 1,
  head     => 1,
  post     => 1,
  delete   => 1,
  trace    => 1,
  mkcol    => 1,
  propfind => 1,
  copy     => 1,
  lock     => 1,
  unlock   => 1,
  move     => 1
);

sub new {
  my ($class) = @_;
  my $self = {};
  bless $self, $class;
  return $self;
}

sub run {
  my ($self, $request, $response) = @_;

  my $fs = $self->filesys || die 'Boom';

  my $method = $request->method;
  my $path   = decode_utf8 uri_unescape $request->uri->path;

  if (!defined $response) {
    $response = HTTP::Response->new;
  }

  $method = lc $method;
  if ($implemented{$method}) {
    $response->code(200);
    $response->message('OK');
    $response = $self->$method($request, $response);
    $response->header('Content-Length' => length($response->content));
  } else {

    # Saying it isn't implemented is better than crashing!
    warn "$method not implemented\n";
    $response->code(501);
    $response->message('Not Implemented');
  }
  return $response;
}

sub options {
  my ($self, $request, $response) = @_;
  $response->header('DAV' => '1,2,<http://apache.org/dav/propset/fs/1>')
    ;    # Nautilus freaks out
  $response->header('MS-Author-Via' => 'DAV');    # Nautilus freaks out
  $response->header('Allow'        => join(',', map { uc } keys %implemented));
  $response->header('Content-Type' => 'httpd/unix-directory');
  $response->header('Keep-Alive'   => 'timeout=15, max=96');
  return $response;
}

sub head {
  my ($self, $request, $response) = @_;
  my $path = decode_utf8 uri_unescape $request->uri->path;
  my $fs   = $self->filesys;

  if ($fs->test("f", $path) && $fs->test("r", $path)) {
    my $fh = $fs->open_read($path);
    $fs->close_read($fh);
    $response->last_modified($fs->modtime($path));
  } elsif ($fs->test("d", $path)) {

    # a web browser, then
    my @files = $fs->list($path);
    $response->header('Content-Type' => 'text/html; charset="utf-8"');
  } else {
    $response = HTTP::Response->new(404, "NOT FOUND", $response->headers);
  }
  return $response;
}

sub get {
  my ($self, $request, $response) = @_;
  my $path = decode_utf8 uri_unescape $request->uri->path;
  my $fs   = $self->filesys;

  if ($fs->test('f', $path) && $fs->test('r', $path)) {
    my $fh = $fs->open_read($path);
    my $file = join '', <$fh>;
    $fs->close_read($fh);
    $response->content($file);
    $response->last_modified($fs->modtime($path));
  } elsif ($fs->test('d', $path)) {

    # a web browser, then
    my @files = $fs->list($path);
    my $body;
    foreach my $file (@files) {
      if ($fs->test('d', $path . $file)) {
        $body .= qq|<a href="$file/">$file/</a><br>\n|;
      } else {
        $file =~ s{/$}{};
        $body .= qq|<a href="$file">$file</a><br>\n|;
      }
    }
    $response->header('Content-Type' => 'text/html; charset="utf-8"');
    $response->content($body);
  } else {
    $response->code(404);
    $response->message('Not Found');
  }
  return $response;
}

sub put {
  my ($self, $request, $response) = @_;
  my $path = decode_utf8 uri_unescape $request->uri->path;
  my $fs   = $self->filesys;

  $response = HTTP::Response->new(201, "CREATED", $response->headers);

  my $fh = $fs->open_write($path);
  print $fh $request->content;
  $fs->close_write($fh);

  return $response;
}

sub _delete_xml {
  my ($dom, $path) = @_;

  my $response = $dom->createElement("d:response");
  $response->appendTextChild("d:href"   => $path);
  $response->appendTextChild("d:status" => "HTTP/1.1 401 Permission Denied")
    ;    # *** FIXME ***
}

sub delete {
  my ($self, $request, $response) = @_;
  my $path = decode_utf8 uri_unescape $request->uri->path;
  my $fs   = $self->filesys;

  if ($request->uri->fragment) {
    return HTTP::Response->new(404, "NOT FOUND", $response->headers);
  }

  unless ($fs->test("e", $path)) {
    return HTTP::Response->new(404, "NOT FOUND", $response->headers);
  }

  my $dom = XML::LibXML::Document->new("1.0", "utf-8");
  my @error;
  foreach my $part (
    grep { $_ !~ m{/\.\.?$} }
    map { s{/+}{/}g; $_ }
    File::Find::Rule::Filesys::Virtual->virtual($fs)->in($path),
    $path
    )
  {

    next unless $fs->test("e", $part);

    if ($fs->test("f", $part)) {
      push @error, _delete_xml($dom, $part)
        unless $fs->delete($part);
    } elsif ($fs->test("d", $part)) {
      push @error, _delete_xml($dom, $part)
        unless $fs->rmdir($part);
    }
  }

  if (@error) {
    my $multistatus = $dom->createElement("D:multistatus");
    $multistatus->setAttribute("xmlns:D", "DAV:");

    $multistatus->addChild($_) foreach @error;

    $response = HTTP::Response->new(207 => "Multi-Status");
    $response->header("Content-Type" => 'text/xml; charset="utf-8"');
  } else {
    $response = HTTP::Response->new(204 => "No Content");
  }
  return $response;
}

sub copy {
  my ($self, $request, $response) = @_;
  my $path = decode_utf8 uri_unescape $request->uri->path;
  my $fs   = $self->filesys;

  my $destination = $request->header('Destination');
  $destination = URI->new($destination)->path;
  my $depth     = $request->header('Depth') || 0;
  my $overwrite = $request->header('Overwrite') || 'F';

  if ($fs->test("f", $path)) {
    return $self->copy_file($request, $response);
  }

  # it's a good approximation
  $depth = 100 if defined $depth && $depth eq 'infinity';

  my @files =
    map { s{/+}{/}g; $_ }
    File::Find::Rule::Filesys::Virtual->virtual($fs)->file->maxdepth($depth)
    ->in($path);

  my @dirs = reverse sort
    grep { $_ !~ m{/\.\.?$} }
    map { s{/+}{/}g; $_ }
    File::Find::Rule::Filesys::Virtual->virtual($fs)
    ->directory->maxdepth($depth)->in($path);

  push @dirs, $path;
  foreach my $dir (sort @dirs) {
    my $destdir = $dir;
    $destdir =~ s/^$path/$destination/;
    if ($overwrite eq 'F' && $fs->test("e", $destdir)) {
      return HTTP::Response->new(401, "ERROR", $response->headers);
    }
    $fs->mkdir($destdir);
  }

  foreach my $file (reverse sort @files) {
    my $destfile = $file;
    $destfile =~ s/^$path/$destination/;
    my $fh = $fs->open_read($file);
    my $file = join '', <$fh>;
    $fs->close_read($fh);
    if ($fs->test("e", $destfile)) {
      if ($overwrite eq 'T') {
        $fh = $fs->open_write($destfile);
        print $fh $file;
        $fs->close_write($fh);
      } else {
      }
    } else {
      $fh = $fs->open_write($destfile);
      print $fh $file;
      $fs->close_write($fh);
    }
  }

  $response = HTTP::Response->new(200, "OK", $response->headers);
  return $response;
}

sub copy_file {
  my ($self, $request, $response) = @_;
  my $path = decode_utf8 uri_unescape $request->uri->path;
  my $fs   = $self->filesys;

  my $destination = $request->header('Destination');
  $destination = URI->new($destination)->path;
  my $depth     = $request->header('Depth');
  my $overwrite = $request->header('Overwrite');

  if ($fs->test("d", $destination)) {
    $response = HTTP::Response->new(204, "NO CONTENT", $response->headers);
  } elsif ($fs->test("f", $path) && $fs->test("r", $path)) {
    my $fh = $fs->open_read($path);
    my $file = join '', <$fh>;
    $fs->close_read($fh);
    if ($fs->test("f", $destination)) {
      if ($overwrite eq 'T') {
        $fh = $fs->open_write($destination);
        print $fh $file;
        $fs->close_write($fh);
      } else {
        $response->code(412);
        $response->message('Precondition Failed');
      }
    } else {
      unless ($fh = $fs->open_write($destination)) {
        $response->code(409);
        $response->message('Conflict');
        return $response;
      }
      print $fh $file;
      $fs->close_write($fh);
      $response->code(201);
      $response->message('Created');
    }
  } else {
    $response->code(404);
    $response->message('Not Found');
  }
  return $response;
}

sub move {
  my ($self, $request, $response) = @_;

  my $destination = $request->header('Destination');
  $destination = URI->new($destination)->path;
  my $destexists = $self->filesys->test("e", $destination);

  $response = $self->copy($request,   $response);
  $response = $self->delete($request, $response)
    if $response->is_success;

  $response->code(201) unless $destexists;

  return $response;
}

sub lock {
  my ($self, $request, $response) = @_;
  my $path = decode_utf8 uri_unescape $request->uri->path;
  my $fs   = $self->filesys;

  $fs->lock($path);

  return $response;
}

sub unlock {
  my ($self, $request, $response) = @_;
  my $path = decode_utf8 uri_unescape $request->uri->path;
  my $fs   = $self->filesys;

  $fs->unlock($path);

  return $response;
}

sub mkcol {
  my ($self, $request, $response) = @_;
  my $path = decode_utf8 uri_unescape $request->uri->path;
  my $fs   = $self->filesys;

  if ($request->content) {
    $response->code(415);
    $response->message('Unsupported Media Type');
  } elsif (not $fs->test("e", $path)) {
    $fs->mkdir($path);
    if ($fs->test("d", $path)) {
    } else {
      $response->code(409);
      $response->message('Conflict');
    }
  } else {
    $response->code(405);
    $response->message('Method Not Allowed');
  }
  return $response;
}

sub propfind {
  my ($self, $request, $response) = @_;
  my $path  = decode_utf8 uri_unescape $request->uri->path;
  my $fs    = $self->filesys;
  my $depth = $request->header('Depth');

  my $reqinfo = 'allprop';
  my @reqprops;
  if ($request->header('Content-Length')) {
    my $content = $request->content;
    my $parser  = XML::LibXML->new;
    my $doc;
    eval { $doc = $parser->parse_string($content); };
    if ($@) {
      $response->code(400);
      $response->message('Bad Request');
      return $response;
    }

    #$reqinfo = doc->find('/DAV:propfind/*')->localname;
    $reqinfo = $doc->find('/*/*')->shift->localname;
    if ($reqinfo eq 'prop') {

      #for my $node ($doc->find('/DAV:propfind/DAV:prop/*')) {
      for my $node ($doc->find('/*/*/*')->get_nodelist) {
        push @reqprops, [ $node->namespaceURI, $node->localname ];
      }
    }
  }

  if (!$fs->test('e', $path)) {
    $response->code(404);
    $response->message('Not Found');
    return $response;
  }

  $response->code(207);
  $response->message('Multi-Status');
  $response->header('Content-Type' => 'text/xml; charset="utf-8"');

  my $doc = XML::LibXML::Document->new('1.0', 'utf-8');
  my $multistat = $doc->createElement('D:multistatus');
  $multistat->setAttribute('xmlns:D', 'DAV:');
  $doc->setDocumentElement($multistat);

  my @paths;
  if (defined $depth && $depth eq 1 and $fs->test('d', $path)) {
    my $p = $path;
    $p .= '/' unless $p =~ m{/$};
    @paths = map { $p . $_ } File::Spec->no_upwards( $fs->list($path) );
    push @paths, $path;
  } else {
    @paths = ($path);
  }

  for my $path (@paths) {
    my (
      $dev,  $ino,   $mode,  $nlink, $uid,     $gid, $rdev,
      $size, $atime, $mtime, $ctime, $blksize, $blocks
      )
      = $fs->stat($path);

    # modified time is stringified human readable HTTP::Date style
    $mtime = time2str($mtime);

    # created time is ISO format
    # tidy up date format - isoz isn't exactly what we want, but
    # it's easy to change.
    $ctime = time2isoz($ctime);
    $ctime =~ s/ /T/;
    $ctime =~ s/Z//;

    $size ||= '';

    my $resp = $doc->createElement('D:response');
    $multistat->addChild($resp);
    my $href = $doc->createElement('D:href');
    $href->appendText(
      File::Spec->catdir(
        map { uri_escape encode_utf8 $_} File::Spec->splitdir($path)
      )
    );
    $resp->addChild($href);
    $href->appendText( '/' ) if $fs->test('d', $path);
    my $okprops = $doc->createElement('D:prop');
    my $nfprops = $doc->createElement('D:prop');
    my $prop;

    if ($reqinfo eq 'prop') {
      my %prefixes = ('DAV:' => 'D');
      my $i        = 0;

      for my $reqprop (@reqprops) {
        my ($ns, $name) = @$reqprop;
        if ($ns eq 'DAV:' && $name eq 'creationdate') {
          $prop = $doc->createElement('D:creationdate');
          $prop->appendText($ctime);
          $okprops->addChild($prop);
        } elsif ($ns eq 'DAV:' && $name eq 'getcontentlength') {
          $prop = $doc->createElement('D:getcontentlength');
          $prop->appendText($size);
          $okprops->addChild($prop);
        } elsif ($ns eq 'DAV:' && $name eq 'getcontenttype') {
          $prop = $doc->createElement('D:getcontenttype');
          if ($fs->test('d', $path)) {
            $prop->appendText('httpd/unix-directory');
          } else {
            $prop->appendText('httpd/unix-file');
          }
          $okprops->addChild($prop);
        } elsif ($ns eq 'DAV:' && $name eq 'getlastmodified') {
          $prop = $doc->createElement('D:getlastmodified');
          $prop->appendText($mtime);
          $okprops->addChild($prop);
        } elsif ($ns eq 'DAV:' && $name eq 'resourcetype') {
          $prop = $doc->createElement('D:resourcetype');
          if ($fs->test('d', $path)) {
            my $col = $doc->createElement('D:collection');
            $prop->addChild($col);
          }
          $okprops->addChild($prop);
        } else {
          my $prefix = $prefixes{$ns};
          if (!defined $prefix) {
            $prefix = 'i' . $i++;

            # mod_dav sets <response> 'xmlns' attribute - whatever
            #$nfprops->setAttribute("xmlns:$prefix", $ns);
            $resp->setAttribute("xmlns:$prefix", $ns);

            $prefixes{$ns} = $prefix;
          }

          $prop = $doc->createElement("$prefix:$name");
          $nfprops->addChild($prop);
        }
      }
    } elsif ($reqinfo eq 'propname') {
      $prop = $doc->createElement('D:creationdate');
      $okprops->addChild($prop);
      $prop = $doc->createElement('D:getcontentlength');
      $okprops->addChild($prop);
      $prop = $doc->createElement('D:getcontenttype');
      $okprops->addChild($prop);
      $prop = $doc->createElement('D:getlastmodified');
      $okprops->addChild($prop);
      $prop = $doc->createElement('D:resourcetype');
      $okprops->addChild($prop);
    } else {
      $prop = $doc->createElement('D:creationdate');
      $prop->appendText($ctime);
      $okprops->addChild($prop);
      $prop = $doc->createElement('D:getcontentlength');
      $prop->appendText($size);
      $okprops->addChild($prop);
      $prop = $doc->createElement('D:getcontenttype');
      if ($fs->test('d', $path)) {
        $prop->appendText('httpd/unix-directory');
      } else {
        $prop->appendText('httpd/unix-file');
      }
      $okprops->addChild($prop);
      $prop = $doc->createElement('D:getlastmodified');
      $prop->appendText($mtime);
      $okprops->addChild($prop);
      do {
        $prop = $doc->createElement('D:supportedlock');
        for my $n (qw(exclusive shared)) {
          my $lock = $doc->createElement('D:lockentry');

          my $scope = $doc->createElement('D:lockscope');
          my $attr  = $doc->createElement('D:' . $n);
          $scope->addChild($attr);
          $lock->addChild($scope);

          my $type = $doc->createElement('D:locktype');
          $attr = $doc->createElement('D:write');
          $type->addChild($attr);
          $lock->addChild($type);

          $prop->addChild($lock);
        }
        $okprops->addChild($prop);
      };
      $prop = $doc->createElement('D:resourcetype');
      if ($fs->test('d', $path)) {
        my $col = $doc->createElement('D:collection');
        $prop->addChild($col);
      }
      $okprops->addChild($prop);
    }

    if ($okprops->hasChildNodes) {
      my $propstat = $doc->createElement('D:propstat');
      $propstat->addChild($okprops);
      my $stat = $doc->createElement('D:status');
      $stat->appendText('HTTP/1.1 200 OK');
      $propstat->addChild($stat);
      $resp->addChild($propstat);
    }

    if ($nfprops->hasChildNodes) {
      my $propstat = $doc->createElement('D:propstat');
      $propstat->addChild($nfprops);
      my $stat = $doc->createElement('D:status');
      $stat->appendText('HTTP/1.1 404 Not Found');
      $propstat->addChild($stat);
      $resp->addChild($propstat);
    }
  }

  $response->content($doc->toString(1));

  return $response;
}

1;

__END__

=head1 NAME

Net::DAV::Server - Provide a DAV Server

=head1 SYNOPSIS

  my $filesys = Filesys::Virtual::Plain->new({root_path => $cwd});
  my $webdav = Net::DAV::Server->new();
  $webdav->filesys($filesys);

  my $d = HTTP::Daemon->new(
    LocalAddr => 'localhost',
    LocalPort => 4242,
    ReuseAddr => 1) || die;
  print "Please contact me at: ", $d->url, "\n";
  while (my $c = $d->accept) {
    while (my $request = $c->get_request) {
      my $response = $webdav->run($request);
      $c->send_response ($response);
    }
    $c->close;
    undef($c);
  }

=head1 DESCRIPTION

This module provides a WebDAV server. WebDAV stands for "Web-based
Distributed Authoring and Versioning". It is a set of extensions to
the HTTP protocol which allows users to collaboratively edit and
manage files on remote web servers.

Net::DAV::Server provides a WebDAV server and exports a filesystem for
you using the Filesys::Virtual suite of modules. If you simply want to
export a local filesystem, use Filesys::Virtual::Plain as above.

This module doesn't currently provide a full WebDAV
implementation. However, I am working through the WebDAV server
protocol compliance test suite (litmus, see
http://www.webdav.org/neon/litmus/) and will provide more compliance
in future. The important thing is that it supports cadaver and the Mac
OS X Finder as clients.

=head1 AUTHOR

Leon Brocard <acme@astray.com>

=head1 MAINTAINERS

  Bron Gondwana <perlcode@brong.net> ( current maintainer )
  Leon Brocard <acme@astray.com>     ( original author )

The latest copy of this package can be checked out using Subversion
from http://svn.brong.net/netdavserver/release

Development code at http://svn.brong.net/netdavserver/trunk


=head1 COPYRIGHT


Copyright (C) 2004, Leon Brocard

This module is free software; you can redistribute it or modify it under
the same terms as Perl itself.

=cut

1
