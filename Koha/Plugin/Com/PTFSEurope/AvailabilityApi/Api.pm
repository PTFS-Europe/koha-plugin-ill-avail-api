package Koha::Plugin::Com::PTFSEurope::AvailabilityApi::Api;

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Modern::Perl;

use JSON qw( encode_json decode_json );

use MIME::Base64 qw( decode_base64 encode_base64 );
use URI::Escape  qw ( uri_unescape );
use POSIX        qw ( floor );
use LWP::UserAgent;
use HTTP::Request::Common;

use Mojo::Base 'Mojolicious::Controller';
use Koha::Plugin::Com::PTFSEurope::AvailabilityApi;

my $base_url      = "redacted";       #TODO: Put this in a config value
my $ua            = LWP::UserAgent->new;
my $plugin_config = get_plugin_config();
my $user          = $plugin_config->{ill_avail_api_userid};
my $pass          = $plugin_config->{ill_avail_api_password};
my $encoded_login = encode_base64( $user . ':' . $pass, '' );

sub search {
    my $c = shift->openapi->valid_input or return;

    my $start      = $c->validation->param('start')    || 0;
    my $metadata   = $c->validation->param('metadata') || '';
    my $pageLength = $c->validation->param('length') == -1 ? 100 : 20;

    my $libraries = get_libraries();

    # ILL request metadata coming from 'create' form
    $metadata = decode_json( decode_base64( uri_unescape($metadata) ) );

    # EBSCO to Koha ILL fieldmap, ordered by most relevant koha field match
    my %fieldmap = (
        TI => [ 'article_title',  'chapter',        'title' ],
        AU => [ 'article_author', 'chapter_author', 'author' ],
        IB => ['isbn'],
        IS => ['issn'],
        TX => ['doi']
    );

    my %params = ();
    foreach my $ebsco_code ( keys %fieldmap ) {
        foreach my $koha_field ( @{ $fieldmap{$ebsco_code} } ) {

            # Check if this koha field exists in the submitted in metadata
            if ( $metadata->{$koha_field} && length $metadata->{$koha_field} > 0 ) {
                $params{$ebsco_code} = $metadata->{$koha_field};

                # Most relevant koha field for this ebsco code was found. Bail
                last;
            }
        }
    }

    # Bail out if we have nothing to search with
    if ( !keys %params ) {
        return_error( $c, 400, 'No searchable metadata found' );
    }

    my $search_params;
    if ( $metadata->{issn} ) {
        push( @{ $search_params->{'-or'} }, [ { 'issn' => $metadata->{issn} } ] );
    }

    if ( $metadata->{title} ) {
        push( @{ $search_params->{'-or'} }, [ { 'title' => { 'like' => '%' . $metadata->{title} . '%' } } ] );
    }

    my @search_headers = (
        'Accept'        => 'application/json',
        'Authorization' => "Basic $encoded_login"
    );

    # Calculate which page of result we're requesting
    my $page            = floor( $start / $pageLength ) + 1;
    my $search_response = $ua->request(
        GET "${base_url}api/v1/biblios?q=" . encode_json($search_params),
        @search_headers
    );

    my $search_body = parse_response(
        $search_response,
        { c => $c, err_code => 500, error => 'Unable to get search results' }
    );

    my $out   = prep_response( $search_body, $libraries );
    my $stats = prep_stats($search_body);

    return $c->render(
        status  => 200,
        openapi => {
            start           => $start,
            pageLength      => scalar @{$out},
            recordsTotal    => $stats->{total},
            recordsFiltered => $stats->{total},
            results         => {
                search_results => $out,
                errors         => []
            }
        }
    );
}

sub get_plugin_config {
    my $plugin = Koha::Plugin::Com::PTFSEurope::AvailabilityApi->new();
    return $plugin->{config};
}

sub prep_stats {
    my $response = shift;

    return {
        total => scalar $response,
    };
}

sub prep_response {
    my $response  = shift;
    my $libraries = shift;

    my $out           = [];
    my $plugin_config = get_plugin_config;

    foreach my $record ( @{$response} ) {

        my @items_req_headers = (

            # 'Accept'                => 'application/marc-in-json',
            'Accept'        => 'application/json',
            'Authorization' => "Basic $encoded_login"
        );

        my $item_url = sprintf(
            '%s/api/v1/biblios/%s/items',
            $base_url,
            $record->{biblio_id},
        );

        push @items_req_headers, ( 'Authorization' => "Basic $encoded_login" );

        # Calculate which page of result we're requesting
        my $items = $ua->request(
            GET sprintf(
                '%s/api/v1/biblios/%s/items',
                $base_url,
                $record->{biblio_id},
            ),
            @items_req_headers
        );

        if ( !$items->is_success ) {
            die 'cant fetch items';    #TODO: Improve this error handling
        }
        my $items_response = decode_json( $items->decoded_content );

        my $url = $base_url . 'cgi-bin/koha/opac-detail.pl?biblionumber=' . $record->{biblio_id};

        my $item_holdings = "Found in:<br>";
        foreach my $item ( @{$items_response} ) {

            $item->{home_library_id} =~ s/^\s+|\s+$//g;
            my ($filtered_library) = grep { $_->{library_id} eq $item->{home_library_id}; } @{$libraries};

            $item_holdings .= $filtered_library->{name} . '<br>';

        }

        my $title  = $item_holdings;
        my $author = $record->{author}         || '';
        my $issn   = $record->{issn}           || '';
        my $isbn   = $record->{isbn}           || '';
        my $date   = $record->{copyright_date} || '';
        my $source = $record->{title}          || '';

        push @{$out}, {
            title  => $source,
            url    => $url,
            author => $author,
            isbn   => $isbn,
            issn   => $issn,
            date   => $date,
            source => $title,
        };
    }
    return $out;
}

sub get_libraries {
    my @libraries_req_headers = (
        'Accept'        => 'application/json',
        'Authorization' => "Basic $encoded_login"
    );

    my $libraries_url = sprintf(
        '%s/api/v1/libraries?_per_page=-1',
        $base_url
    );

    # Calculate which page of result we're requesting
    my $libraries = $ua->request(
        GET $libraries_url,
        @libraries_req_headers
    );

    if ( !$libraries->is_success ) {
        die 'cant fetch libraries';    #TODO: Improve this error handling
    }
    return decode_json( $libraries->decoded_content );
}

sub parse_response {
    my ( $response, $config ) = @_;
    if ( !$response->is_success ) {
        return_error(
            $config->{c},
            $config->{err_code},
            "$config->{error}: $response->status_line"
        );
    }
    return decode_json( $response->decoded_content );
}

sub return_error {
    my ( $c, $code, $error ) = @_;
    return $c->render(
        status  => $code,
        openapi => {
            results => {
                search_results => [],
                errors         => [ { message => $error } ]
            }
        }
    );
}

1;
