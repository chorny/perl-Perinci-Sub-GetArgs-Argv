package Perinci::Sub::GetArgs::Argv;

use 5.010001;
use strict;
use warnings;
use Log::Any '$log';

use Data::Sah;
use Function::Fallback::CoreOrPP qw(clone);
use Perinci::Sub::GetArgs::Array qw(get_args_from_array);
use Perinci::Sub::Util qw(err);

use Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(get_args_from_argv);

# VERSION

our %SPEC;

my $re_simple_scalar = qr/^(str|num|int|float|bool)$/;

# retun ($success?, $errmsg, $res)
sub _parse_json {
    require Data::Clean::FromJSON;
    require JSON;

    my $str = shift;

    state $json = JSON->new->allow_nonref;

    # to rid of those JSON::XS::Boolean objects which currently choke
    # Data::Sah-generated validator code. in the future Data::Sah can be
    # modified to handle those, or we use a fork of JSON::XS which doesn't
    # produce those in the first place (probably only when performance is
    # critical).
    state $cleanser = Data::Clean::FromJSON->get_cleanser;

    my $res;
    eval { $res = $json->decode($str); $cleanser->clean_in_place($res) };
    my $e = $@;
    return (!$e, $e, $res);
}

sub _parse_yaml {
    require YAML::Syck;

    my $str = shift;

    local $YAML::Syck::ImplicitTyping = 1;
    my $res;
    eval { $res = YAML::Syck::Load($str) };
    my $e = $@;
    return (!$e, $e, $res);
}

$SPEC{get_args_from_argv} = {
    v => 1.1,
    summary => 'Get subroutine arguments (%args) from command-line arguments '.
        '(@ARGV)',
    description => <<'_',

Using information in function metadata's 'args' property, parse command line
arguments '@argv' into hash '%args', suitable for passing into subs.

Currently uses Getopt::Long's GetOptions to do the parsing.

As with GetOptions, this function modifies its 'argv' argument.

Why would one use this function instead of using Getopt::Long directly? Among
other reasons, we want to be able to parse complex types.

This function exists mostly to support command-line options parsing for
Perinci::CmdLine. See its documentation, on the section of command-line
options/argument parsing.

_
    args => {
        argv => {
            schema => ['array*' => {
                of => 'str*',
            }],
            description => 'If not specified, defaults to @ARGV',
        },
        meta => {
            schema => ['hash*' => {}],
            req => 1,
        },
        check_required_args => {
            schema => ['bool'=>{default=>1}],
            summary => 'Whether to check required arguments',
            description => <<'_',

If set to true, will check that required arguments (those with req=>1) have been
specified. Normally you want this, but Perinci::CmdLine turns this off so users
can run --help even when arguments are incomplete.

_
        },
        strict => {
            schema => ['bool' => {default=>1}],
            summary => 'Strict mode',
            description => <<'_',

If set to 0, will still return parsed argv even if there are parsing errors. If
set to 1 (the default), will die upon error.

Normally you would want to use strict mode, for more error checking. Setting off
strict is used by, for example, Perinci::Sub::Complete.

_
        },
        per_arg_yaml => {
            schema => ['bool' => {default=>0}],
            summary => 'Whether to recognize --ARGNAME-yaml',
            description => <<'_',

This is useful for example if you want to specify a value which is not
expressible from the command-line, like 'undef'.

    % script.pl --name-yaml '~'

See also: per_arg_json. You should enable just one instead of turning on both.

_
        },
        per_arg_json => {
            schema => ['bool' => {default=>0}],
            summary => 'Whether to recognize --ARGNAME-json',
            description => <<'_',

This is useful for example if you want to specify a value which is not
expressible from the command-line, like 'undef'.

    % script.pl --name-json 'null'

But every other string will need to be quoted:

    % script.pl --name-json '"foo"'

See also: per_arg_yaml. You should enable just one instead of turning on both.

_
        },
        extra_getopts_before => {
            schema => ['array' => {}],
            summary => 'Specify extra Getopt::Long specification',
            description => <<'_',

If specified, insert extra Getopt::Long specification. This is used, for
example, by Perinci::CmdLine::run() to add general options --help, --version,
--list, etc so it can mixed with spec arg options, for convenience.

Since the extra specification is put at the front (before function arguments
specification), the extra options will not be able to override function
arguments (this is how Getopt::Long works). For example, if extra specification
contains --help, and one of function arguments happens to be 'help', the extra
specification won't have any effect.

_
        },
        extra_getopts_after => {
            schema => ['array' => {}],
            summary => 'Specify extra Getopt::Long specification',
            description => <<'_',

Just like *extra_getopts_before*, but the extra specification is put _after_
function arguments specification so extra options can override function
arguments.

_
        },
        allow_extra_elems => {
            schema => ['bool' => {default=>0}],
            summary => 'Allow extra/unassigned elements in argv',
            description => <<'_',

If set to 1, then if there are array elements unassigned to one of the
arguments, instead of generating an error, the function will just ignore them.

This option will be passed to Perinci::Sub::GetArgs::Array's allow_extra_elems.

_
        },
        on_missing_required_args => {
            schema => 'code',
            summary => 'Execute code when there is missing required args',
            description => <<'_',

This can be used to give a chance to supply argument value from other sources if
not specified by command-line options. Perinci::CmdLine, for example, uses this
hook to supply value from STDIN or file contents (if argument has `cmdline_src`
specification key set).

This hook will be called for each missing argument. It will be supplied hash
arguments: (arg => $the_missing_argument_name, args =>
$the_resulting_args_so_far, spec => $the_arg_spec).

The hook can return true if it succeeds in making the missing situation
resolved. In this case, the function won't complain about missing argument for
the corresponding argument.

_
        },
    },
    result => {
        description => <<'_',

Error codes:

* 500 - failure in GetOptions, meaning argv is not valid according to metadata
  specification.

* 502 - coderef in cmdline_aliases got converted into a string, probably because
  the metadata was transported (e.g. through Riap::HTTP/Riap::Simple).

_
    },
};
sub get_args_from_argv {
    require Getopt::Long;

    my %input_args = @_;
    my $argv       = $input_args{argv} // \@ARGV;
    my $meta       = $input_args{meta} or return [400, "Please specify meta"];
    my $v = $meta->{v} // 1.0;
    return [412, "Only metadata version 1.1 is supported, given $v"]
        unless $v == 1.1;
    my $args_p     = clone($meta->{args} // {});
    my $strict     = $input_args{strict} // 1;
    my $extra_go_b = $input_args{extra_getopts_before} // [];
    my $extra_go_a = $input_args{extra_getopts_after} // [];
    my $per_arg_yaml = $input_args{per_arg_yaml} // 0;
    my $per_arg_json = $input_args{per_arg_json} // 0;
    my $allow_extra_elems = $input_args{allow_extra_elems} // 0;
    my $on_missing = $input_args{on_missing_required_args};
    $log->tracef("-> get_args_from_argv(), argv=%s", $argv);

    # the resulting args
    my $args = {};

    my @go_spec;

    # 1. first we form Getopt::Long spec

    for my $a (keys %$args_p) {
        my $as = $args_p->{$a};
        $as->{schema} = Data::Sah::normalize_schema($as->{schema} // 'any');
        # XXX normalization of 'of' clause should've been handled by sah itself
        if ($as->{schema}[0] eq 'array' && $as->{schema}[1]{of}) {
            $as->{schema}[1]{of} = Data::Sah::normalize_schema(
                $as->{schema}[1]{of});
        }
        my $go_opt;
        $a =~ s/_/-/g; # arg_with_underscore becomes --arg-with-underscore
        my @name = ($a);
        my $name2go_opt = sub {
            my ($name, $schema) = @_;
            if ($schema->[0] eq 'bool') {
                if (length($name) == 1 || $schema->[1]{is}) {
                    # single-letter option like -b doesn't get --nob.
                    # [bool=>{is=>1}] also means it's a flag and should not get
                    # --nofoo.
                    return $name;
                } else {
                    return "$name!";
                }
            } else {
                return "$name=s";
            }
        };
        my $arg_key;
        for my $name (@name) {
            unless (defined $arg_key) { $arg_key = $name; $arg_key =~ s/-/_/g }
            $name =~ s/\./-/g;
            $go_opt = $name2go_opt->($name, $as->{schema});
            my $type = $as->{schema}[0];
            my $cs   = $as->{schema}[1];
            my $is_simple_scalar = $type =~ $re_simple_scalar;
            my $is_array_of_simple_scalar = $type eq 'array' &&
                $cs->{of} && $cs->{of}[0] =~ $re_simple_scalar;
            #$log->errorf("TMP:$name ss=%s ass=%s",
            #             $is_simple_scalar, $is_array_of_simple_scalar);

            # why we use coderefs here? due to getopt::long's behavior. when
            # @ARGV=qw() and go_spec is ('foo=s' => \$opts{foo}) then %opts will
            # become (foo=>undef). but if go_spec is ('foo=s' => sub {
            # $opts{foo} = $_[1] }) then %opts will become (), which is what we
            # prefer, so we can later differentiate "unspecified"
            # (exists($opts{foo}) == false) and "specified as undef"
            # (exists($opts{foo}) == true but defined($opts{foo}) == false).

            my $go_handler = sub {
                my ($val, $val_set);
                if ($is_array_of_simple_scalar) {
                    $args->{$arg_key} //= [];
                    $val_set = 1; $val = $_[1];
                    push @{ $args->{$arg_key} }, $val;
                } elsif ($is_simple_scalar) {
                    $val_set = 1; $val = $_[1];
                    $args->{$arg_key} = $val;
                } else {
                    {
                        my ($success, $e, $decoded);
                        ($success, $e, $decoded) = _parse_json($_[1]);
                        if ($success) {
                            $val_set = 1; $val = $decoded;
                            $args->{$arg_key} = $val;
                            last;
                        }
                        ($success, $e, $decoded) = _parse_yaml($_[1]);
                        if ($success) {
                            $val_set = 1; $val = $decoded;
                            $args->{$arg_key} = $val;
                            last;
                        }
                        die "Invalid YAML/JSON in arg '$arg_key'";
                    }
                }
                # XXX special parsing of type = date

                if ($val_set && $as->{cmdline_on_getopt}) {
                    $as->{cmdline_on_getopt}->(
                        arg=>$name, value=>$val, args=>$args,
                        opt=>$_[0]{ctl}[1], # option name
                    );
                }
            };
            push @go_spec, $go_opt => $go_handler;

            if ($per_arg_json && $as->{schema}[0] ne 'bool') {
                push @go_spec, "$name-json=s" => sub {
                    my ($success, $e, $decoded);
                    ($success, $e, $decoded) = _parse_json($_[1]);
                    if ($success) {
                        $args->{$arg_key} = $decoded;
                    } else {
                        die "Invalid JSON in option --$name-json: $_[1]: $e";
                    }
                };
            }
            if ($per_arg_yaml && $as->{schema}[0] ne 'bool') {
                push @go_spec, "$name-yaml=s" => sub {
                    my ($success, $e, $decoded);
                    ($success, $e, $decoded) = _parse_yaml($_[1]);
                    if ($success) {
                        $args->{$arg_key} = $decoded;
                    } else {
                        die "Invalid YAML in option --$name-yaml: $_[1]: $e";
                    }
                };
            }

            # parse argv_aliases
            if ($as->{cmdline_aliases}) {
                for my $al (keys %{$as->{cmdline_aliases}}) {
                    my $alspec = $as->{cmdline_aliases}{$al};
                    my $type =
                        $alspec->{schema} ? $alspec->{schema}[0] :
                            $as->{schema} ? $as->{schema}[0] : '';
                    if ($alspec->{code} && $type eq 'bool') {
                        # bool --alias doesn't get --noalias if has code
                        $go_opt = $al; # instead of "$al!"
                    } else {
                        $go_opt = $name2go_opt->(
                            $al, $alspec->{schema} // $as->{schema});
                    }

                    if ($alspec->{code}) {
                        if ($alspec->{code} eq 'CODE') {
                            if (grep {/\A--\Q$al\E(-yaml|-json)?(=|\z)/}
                                    @$argv) {
                                return [
                                    502,
                                    join("",
                                         "Code in cmdline_aliases for arg $a ",
                                         "got converted into string, probably ",
                                         "because of JSON transport"),
                                ];
                            }
                        }
                        push @go_spec,
                            $go_opt=>sub {$alspec->{code}->($args, $_[1])};
                    } else {
                        push @go_spec, $go_opt=>$go_handler;
                    }
                }
            }
        }
    }

    # 2. then we run GetOptions to fill $args from command-line opts

    @go_spec = (@$extra_go_b, @go_spec, @$extra_go_a);
    $log->tracef("GetOptions spec: %s", \@go_spec);
    my $old_go_opts = Getopt::Long::Configure(
        $strict ? "no_pass_through" : "pass_through",
        "no_ignore_case", "permute", "bundling", "no_getopt_compat");
    my $result = Getopt::Long::GetOptionsFromArray($argv, @go_spec);
    Getopt::Long::Configure($old_go_opts);
    unless ($result) {
        return [500, "GetOptions failed"] if $strict;
    }

    # 3. then we try to fill $args from remaining command-line arguments (for
    # args which have 'pos' spec specified)

    if (@$argv) {
        my $res = get_args_from_array(
            array=>$argv, _args_p=>$args_p,
            allow_extra_elems => $allow_extra_elems,
        );
        if ($res->[0] != 200 && $strict) {
            return err(500, "Get args from array failed", $res);
        } elsif ($res->[0] == 200) {
            my $pos_args = $res->[2];
            for my $name (keys %$pos_args) {
                my $as  = $args_p->{$name};
                my $val = $pos_args->{$name};
                if (exists $args->{$name}) {
                    return [400, "You specified option --$name but also ".
                                "argument #".$as->{pos}] if $strict;
                }
                my $type = $as->{schema}[0];
                my $cs   = $as->{schema}[1];
                my $is_simple_scalar = $type =~ $re_simple_scalar;
                my $is_array_of_simple_scalar = $type eq 'array' &&
                    $cs->{of} && $cs->{of}[0] =~ $re_simple_scalar;

                if ($as->{greedy} && ref($val) eq 'ARRAY') {
                    # try parsing each element as JSON/YAML
                    my $i = 0;
                    for (@$val) {
                        {
                            my ($success, $e, $decoded);
                            ($success, $e, $decoded) = _parse_json($_);
                            if ($success) {
                                $_ = $decoded;
                                last;
                            }
                            ($success, $e, $decoded) = _parse_yaml($_);
                            if ($success) {
                                $_ = $decoded;
                                last;
                            }
                            die "Invalid JSON/YAML in #$as->{pos}\[$i]";
                        }
                        $i++;
                    }
                }
                if (!$as->{greedy} && !$is_simple_scalar) {
                    # try parsing as JSON/YAML
                    my ($success, $e, $decoded);
                    ($success, $e, $decoded) = _parse_json($val);
                    {
                        if ($success) {
                            $val = $decoded;
                            last;
                        }
                        ($success, $e, $decoded) = _parse_yaml($val);
                        if ($success) {
                            $val = $decoded;
                            last;
                        }
                        die "Invalid JSON/YAML in #$as->{pos}";
                    }
                }
                $args->{$name} = $val;
                # we still call cmdline_on_getopt for this
                if ($as->{cmdline_on_getopt}) {
                    if ($as->{greedy}) {
                        $as->{cmdline_on_getopt}->(
                            arg=>$name, value=>$_, args=>$args,
                            opt=>undef, # this marks that value is retrieved from cmdline arg
                        ) for @$val;
                    } else {
                        $as->{cmdline_on_getopt}->(
                            arg=>$name, value=>$val, args=>$args,
                            opt=>undef, # this marks that value is retrieved from cmdline arg
                        );
                    }
                }
            }
        }
    }

    # 4. check required args

    my $missing_arg;
    for my $a (keys %$args_p) {
        my $as = $args_p->{$a};
        if (!exists($args->{$a})) {
            next unless $as->{req};
            # give a chance to hook to set missing arg
            if ($on_missing) {
                next if $on_missing->(arg=>$a, args=>$args, spec=>$as);
            }
            next if exists $args->{$a};
            $missing_arg = $a;
            if (($input_args{check_required_args} // 1) && $strict) {
                return [400, "Missing required argument: $a"];
            }
        }
    }

    $log->tracef("<- get_args_from_argv(), args=%s, remaining argv=%s",
                 $args, $argv);
    [200, "OK", $args, {"func.missing_arg"=>$missing_arg}];
}

1;
#ABSTRACT: Get subroutine arguments from command line arguments (@ARGV)

=head1 SYNOPSIS

 use Perinci::Sub::GetArgs::Argv;

 my $res = get_args_from_argv(argv=>\@ARGV, meta=>$meta, ...);


=head1 DESCRIPTION

This module provides C<get_args_from_argv()>, which parses command line
arguments (C<@ARGV>) into subroutine arguments (C<%args>). This module is used
by L<Perinci::CmdLine>. For explanation on how command-line options are
processed, see Perinci::CmdLine's documentation.

This module uses L<Log::Any> for logging framework.

This module has L<Rinci> metadata.


=head1 FAQ


=head1 SEE ALSO

L<Perinci>

=cut
