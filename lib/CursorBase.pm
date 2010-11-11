#!perl

# CursorBase.pmc
#
# Copyright 2008-2010, Larry Wall
#
# You may copy this software under the terms of the Artistic License,
#     version 2.0 or later.

use strict;
use warnings;
no warnings 'recursion';
use utf8;
use NAME;
use Stash;
use RE_ast;
#use Carp::Always;
use File::Spec ();
use File::Basename ();
use File::ShareDir ();
use File::Path ();
use Config;

my $TRIE = 1;
my $STORABLE = 1;

use feature 'say', 'state';

require 'mangle.pl';

our $CTX = '';
BEGIN {
    $::DEBUG //= 0 + ($ENV{STD5DEBUG} // 0);
}
our $DEBUG;
use constant DEBUG => $::DEBUG;
our %LEXERS;       # per language, the cache of lexers, keyed by rule identity
our %FATECACHE; # fates we've already turned into linked lists
my %lexer_cache = ();

sub ::fatestr { my $f = shift;
    my $text = '';
    while ($f) {
        $text .= $f->[1] . " " . $f->[2];
        $text .= ' ' if $f = $f->[0];
    }
    $text;
}

use DEBUG;

sub ::deb {
    print ::LOG @_, "\n";
}

package CursorBase;

use Carp;
use File::Copy;
use YAML::XS;
use Storable;
use Encode;
use Scalar::Util 'refaddr';
use Try::Tiny;

use Term::ANSIColor;
our $BLUE = color 'blue';
our $GREEN = color 'green';
our $CYAN = color 'cyan';
our $MAGENTA = color 'magenta';
our $YELLOW = color 'yellow';
our $RED = color 'red';
our $CLEAR = color 'clear';

use STD::LazyMap qw(lazymap eager);
use constant DEBUG => $::DEBUG;

our $REGEXES = { ALL => [] };

BEGIN {
    require Moose;
    # this prevents us from inheriting from Moose::Object, which saves a
    # good 20 seconds on DESTROY/DEMOLISHALL
    Moose::Meta::Class->create('CursorBase');
}

our $data_dir;
BEGIN {
    # 2 possibilities:
    #   * STD is installed.  CursorBase will be in the system @INC somewhere,
    #     with nothing but other modules besides it.  Use File::ShareDir.
    #   * STD is being used in place.  uniprops will be in the same dir as
    #     CursorBase.pm

    # yes, the INC entry always uses forward slashes and ends in .pm, always
    my $path = __PACKAGE__;
    $path =~ s#::#/#g;

    $data_dir = File::Basename::dirname($INC{"$path.pm"});
    if (! -e File::Spec->catfile($data_dir, "uniprops")) {
        $data_dir = File::ShareDir::dist_dir('STD');
    }
}
$::PERL6HERE = $ENV{PERL6HERE} // '⏏';
Encode::_utf8_on($::PERL6HERE);

binmode(STDIN, ":utf8");
binmode(STDERR, ":utf8");
binmode(STDOUT, ":utf8");
BEGIN {
    if ($^P || !DEBUG) {
        open(::LOG, ">&1") or die "Can't create $0.log: $!";
    }
    else {
        open(::LOG, ">$0.log") or die "Can't create $0.log: $!";
    }
    binmode(::LOG, ":utf8");
}

#############################################################
# STD::Cursor Accessors
#############################################################

sub _PARAMS {}  # overridden in parametric role packages

sub from :lvalue { $_[0]->{_from} //= $_[0]->{_pos} }
sub to { $_[0]->{_pos} }
sub pos :lvalue { $_[0]->{_pos} }
sub chars { $_[0]->{_pos} - ($_[0]->{_from} // $_[0]->{_pos}) }
sub Str { no warnings; exists $_[0]->{_from} && defined $_[0]->{_pos} ? substr($::ORIG, $_[0]->{_from}, $_[0]->{_pos} - $_[0]->{_from})//'' : '' }
sub xact { $_[0]->{_xact} // die "internal error: cursor has no xact!!!" }
sub orig { \$::ORIG }
sub WHAT { ref $_[0] || $_[0] }

sub item { $_[0] }
sub caps { $_[0] && $_[0]->{'~CAPS'} ? @{$_[0]->{'~CAPS'}} : () }
sub chunks { die "unimpl" }
sub ast { exists $_[0]->{'_ast'} ? $_[0]->{'_ast'} : $_[0]->Str }
sub make { $_[0]->{'_ast'} = $_[1]; $_[0] }

sub label_id {
    bless { 'file' => $::FILE->{name}, 'pos' => $_[0]->{_pos} }, 'LABEL';
}

sub list { my $self = shift;
    my @result;
    # can't just do this in numerical order because some might be missing
    # and we don't know the max
    for my $k (keys %$self) {
        $result[$k] = $self->{$k} if $k =~ /^\d/;
    }
    \@result;
}

sub hash { my $self = shift;
    my %result;
    for my $k (keys %$self) {
        $result{$k} = $self->{$k} if $k !~ /^[_\d~]/;
    }
    \%result;
}

sub deb { my $self = shift;
    my $pos = ref $self && defined $self->{_pos} ? $self->{_pos} : "?";
    print ::LOG $pos,'/',$self->lineof($pos), "\t", $CTX, ' ', @_, "\n";
}

sub clean {
    my $self = shift;
    delete $self->{_fate};
    delete $self->{_pos};       # EXPR blows up without this for some reason
    delete $self->{_reduced};
    for my $k (values %$self) {
        next unless ref $k;
        if (ref $k eq 'ARRAY') {
            for my $k2 (@$k) {
                eval {
                    $k2->clean if ref $k2;
                }
            }
        }
        else {
            eval {
                $k->clean;
            }
        }
    }
    $self;
}

sub dump {
    my $self = shift;
    my %copy = %$self;
    my $text = YAML::XS::Dump(\%copy);
    $text;
}

#############################################################
# System interface
#############################################################

sub sys_compile_module {
    my ($self, $module, $symlfile, $modfile) = @_;

    # should be per-module
    local $STD::ALL;
    local @STD::herestub;
    local $::SETTING;
    local $::CORE;
    local $::GLOBAL;
    local $::UNIT;
    local $::YOU_WERE_HERE;

    # should only apply to the toplevel
    local $::moreinput;

    # STD is missing contextualizers for these, at least in some cases
    local $::CCSTATE;
    local $::BORG;
    local %::RX;
    local $::XACT;
    local $::IN_REDUCE;
    local $::VAR;

    $self->sys_do_compile_module($module, $symlfile, $modfile);
}

sub sys_do_compile_module {
    my ($self, $mod, $syml, $file) = @_;

    $self->parsefile($file,
        setting => $ENV{DEFAULT_SETTING_FOR_MODULES} // "CORE",
        syml_search_path => $::SYML_SEARCH_PATH,
        tmp_prefix => $::TMP_PREFIX);

    print STDERR "Compiled $file\n";
}

sub sys_save_syml {
    my ($self, $all) = @_;

    my $file = $::FILE->{name};
    $file = $::UNIT->{'$?LONGNAME'};
    my @toks = split '::', $file;
    $toks[-1] .= '.syml';
    $file = File::Spec->catfile($::TMP_PREFIX, "syml", @toks);
    pop @toks;
    my $path = File::Spec->catdir($::TMP_PREFIX, "syml", @toks);

    File::Path::mkpath($path);

    open(SETTING, ">", $file) or die "Can't open new setting file $file: $!";
    print SETTING Dump($all);
    close SETTING;
}

sub sys_get_perl6lib {
    my $self = shift;

    if (not @::PERL6LIB) {
        if ($ENV{PERL6LIB} && !$CursorBase::NOPERL6LIB) {
            @::PERL6LIB = split /\Q$Config::Config{path_sep}/, $ENV{PERL6LIB};
        } else {
            @::PERL6LIB = qw< ./lib . >;
        }
    }

    @::PERL6LIB;
}

sub sys_find_module {
    my $self = shift;
    my $module = shift;
    my $issetting = shift;

    my @toks = split '::', $module;
    my $end = pop @toks;

    for my $d ($self->sys_get_perl6lib) {
        for my $ext (qw( .setting .pm6 .pm )) {
            next if ($issetting xor ($ext eq '.setting'));

            my $file = File::Spec->catfile($d, @toks, "$end$ext");
            next unless -f $file;

            if ($ext eq '.pm') {
                local $/;
                open my $pm, "<", $file or next;
                my $pmtx = <$pm>;
                close $pm;
                next if $pmtx =~ /^\s*package\s+\w+\s*;/m; # ignore p5 code
            }

            return $file;
        }
    }

    $self->sorry("Can't locate module $module");
    return;
}

sub sys_load_modinfo {
    my $self = shift;
    my $module = shift;

    my @toks = split '::', $module;
    $toks[-1] .= ".syml";

    my @extra = @$::SYML_SEARCH_PATH;
    shift @extra;
    for my $prefix (@extra) {
        my $file = File::Spec->catfile($prefix, 'syml', @toks);
        if (-e $file) {
            return LoadFile($file);
        }
    }

    my ($symlfile) = File::Spec->catfile($::TMP_PREFIX, 'syml', @toks);
    my ($modfile) = $self->sys_find_module($module, 0)
        or return undef;

    unless (-f $symlfile and -M $modfile > -M $symlfile) {
        $self->sys_compile_module($module, $symlfile, $modfile);
    }
    return LoadFile($symlfile);
}

sub load_lex {
    my $self = shift;
    my $setting = shift;

    if ($setting eq 'NULL') {
        my $id = "MY:file<NULL.pad>:line(1):pos(0)";
        my $core = Stash->new('!id' => [$id], '!file' => 'NULL.pad',
            '!line' => 1);
        return Stash->new('CORE' => $core, 'MY:file<NULL.pad>' => $core,
            'SETTING' => $core, $id => $core);
    }

    for my $prefix (@{$::SYML_SEARCH_PATH}) {
        my $file = File::Spec->catfile($prefix, 'syml', "$setting.syml");
        if (-e $file) {
            return bless($self->_load_yaml_lex($setting,$file),'Stash');
        }
    }

    die "Unable to load setting $setting.  Did you run make?";
}

sub _load_yaml_lex {
    my $self = shift;
    my $setting = shift;
    my $file = shift;
    state %LEXS;
    return $LEXS{$setting} if $LEXS{$setting};
    # HACK YAML::XS is horribly broken see https://rt.cpan.org/Public/Bug/Display.html?id=53278
    $LEXS{$setting} = {%{LoadFile($file)}};
    # say join ' ', sort keys %{ $LEXS{$setting} };
    $LEXS{$setting};
}

sub LoadFile {
    my $file = shift;
    open my $fh, $file or die "Can't open $file: $!";
    my $text = do { local $/; <$fh>; };
    close $fh;
    Load($text);
}

#############################################################
# Setup/Teardown
#############################################################

sub new {
    my $class = shift;
#    $::ORIG = shift;
    { no warnings; @::ORIG = unpack("U*", $::ORIG); }
    $::MEMOS[@::ORIG] = undef;  # memos kept by position
    my %args = ('_pos' => 0, '_from' => 0);
    while (@_) {
        my $name = shift;
        $args{'_' . $name} = shift;
    }
    my $self = bless \%args, ref $class || $class;
    $self->{_xact} = ['MATCH',0,0];
    $self;
}

sub parse {
    my $class = shift;
    my $text = shift;
    my %args = @_;
    local $::FILE = { name => $args{'filename'} // '(eval)' };
    $class->initparse($text,@_);
}

sub parsefile {
    my $class = shift;
    my $file = shift;
    my %args = @_;
    $file =~ s/::/\//g;
    local $::FILE = { name => $file };
    open(FILE, '<:utf8', $file) or die "Can't open $file: $!\n";
    my $text;
    {
        local $/;
        $text = <FILE>;
        close FILE;
    }

    my $result;
    $result = $class->initparse($text,@_,filename => $file);

    $result;
}

## method initparse ($text, :$rule = 'TOP', :$tmp_prefix = '', :$setting = 'CORE', :$actions = '')
sub initparse {
    my $self = shift;
    my $text = shift;
    my %args = @_;
    my $rule = $args{rule} // 'TOP';
    my $tmp_prefix = $args{tmp_prefix} // $CursorBase::SET_STD5PREFIX // $ENV{STD5PREFIX} // '.';
    my $setting = $args{setting} // 'CORE';
    my $actions = $args{actions} // '';
    my $filename = $args{filename};

    local $::TMP_PREFIX = $tmp_prefix;
    local $::SYML_SEARCH_PATH = $args{syml_search_path} //
        $CursorBase::NOSTDSYML ? [$::TMP_PREFIX] : [$::TMP_PREFIX, $data_dir];

    local $::SETTINGNAME = $setting;
    local $::ACTIONS = $actions;
    local $::RECURSIVE_PERL = $args{recursive_perl};
    local @::MEMOS = ();

    local @::ACTIVE = ();

    # various bits of info useful for error messages
    local $::HIGHWATER = 0;
    local $::HIGHMESS = '';
    local $::HIGHEXPECT = {};
    local $::LASTSTATE;
    local $::LAST_NIBBLE = bless { firstline => 0, lastline => 0 }, 'STD::Cursor';
    local $::LAST_NIBBLE_MULTILINE = bless { firstline => 0, lastline => 0 }, 'STD::Cursor';
    local $::GOAL = "(eof)";
    $text .= "\n" unless substr($text,-1,1) eq "\n";
    local $::ORIG = $text;           # original string
    local @::ORIG;

    # This isn't the way it should work; each parse node should instead carry
    # a reference to the string.  But that's a bit tricky to make work right
    # in perl 5.
    if ($args{text_return}) {
        ${$args{text_return}} = $text;
    }

    my $result = $self->new()->$rule();
    delete $result->{_xact};

    # XXX here attach stuff that will enable :cont
    if ($::YOU_WERE_HERE) {
        $result->you_were_here;
    }
    elsif ($args{filename} && $args{filename} =~ /\.pm6?$/) {
        $result->you_were_here;
    }

    $result;
}

sub you_are_here {
    my $self = shift;
    $::YOU_WERE_HERE = $::CURLEX;
    $self;
}

sub you_were_here {
    my $self = shift;
    my $all;
    # setting?
    if ($::YOU_WERE_HERE) {
        $all = $STD::ALL;
        $all->{SETTING} = $::YOU_WERE_HERE;
        $all->{CORE} = $::YOU_WERE_HERE if $::UNIT->{'$?LONGNAME'} eq 'CORE';
    }
    else {
        eval { $::UNIT->{'$?SETTING_ID'} = $STD::ALL->{SETTING}->id };
        warn $@ if $@;
        eval { $::UNIT->{'$?CORE_ID'} = $STD::ALL->{CORE}->id };
        warn $@ if $@;

        $all = {};
        for my $key (keys %{$STD::ALL}) {
            next if $key =~ /^MY:file<\w+\.setting>/ or $key eq 'CORE' or $key eq 'SETTING';
            $all->{$key} = $STD::ALL->{$key};
        }
    }

    $self->sys_save_syml($all);
    $self;
}

sub delete {
    my $self = shift;
    delete $self->{@_};
}

{ package Match;
    sub new { my $self = shift;
        my %args = @_;
        bless \%args, $self;
    }

    sub from { my $self = shift;
        $self->{_f};
    }

    sub to { my $self = shift;
        $self->{_t};
    }
}

#############################################################
# STD::Cursor transformations
#############################################################

sub cursor_xact { 
    if (DEBUG & DEBUG::cursors) {
        my $self = shift;
        my $name = shift;
        my $pedigree = '';
        for (my $x = $self->{_xact}; $x; $x = $x->[-1]) {
            my $n = $x->[0];
            $n =~ s/^RULE // or
            $n =~ s/^ALT *//;
            $pedigree .= ($x->[-2] ? " - " : " + ") . $n;
        }
        $self->deb("cursor_xact $name$pedigree");
        $self->{_xact} = [$name,0,$self->{_xact}];
        return $self;
    }
    # doing this in place is slightly dangerous, but seems to work
    $_[0]->{_xact} = [$_[1],0,$_[0]->{_xact}];
    return $_[0];
}

sub cursor_fresh { my $self = shift;
    my %r;
    my $lang = @_ && $_[0] ? shift() : ref $self;
    $self->deb("cursor_fresh lang $lang") if DEBUG & DEBUG::cursors;
    @r{'_pos','_fate','_xact'} = @$self{'_pos','_fate','_xact'};
    $r{_herelang} = $self->{_herelang} if $self->{_herelang};
    bless \%r, ref $lang || $lang;
}

sub cursor_herelang { my $self = shift;
    $self->deb("cursor_herelang") if DEBUG & DEBUG::cursors;
    my %r = %$self;
    $r{_herelang} = $self;
    bless \%r, 'STD::Q';
}

sub prepbind {
    my $self = shift;
    delete $self->{_fate};
    delete $_->{_xact} for @_;
    $self;
}

sub cursor_bind { my $self = shift;     # this is parent's match cursor
    my $bindings = shift;
    my $submatch = shift;               # this is the submatch's cursor
    $self->prepbind($submatch);

    $self->deb("cursor_bind @$bindings") if DEBUG & DEBUG::cursors;
    my @caps;
    @caps = @{$self->{'~CAPS'}} if $self->{'~CAPS'};  # must copy elems
    my %r = %$self;
    if ($bindings) {
        for my $binding (@$bindings) {
            if (ref $r{$binding} eq 'ARRAY') {
                push(@{$r{$binding}}, $submatch);
            }
            else {
                $r{$binding} = $submatch;
            }
            next if $binding eq 'PRE';
            next if $binding eq 'POST';
            push @caps, $binding, $submatch;
        }
        $r{'~CAPS'} = \@caps;
    }
    $submatch->{_from} = $r{_from} = $r{_pos};
    $r{_pos} = $submatch->{_pos};
    $r{_xact} = $self->{_xact};
    bless \%r, ref $self;               # return new match cursor for parent
}

sub cursor_fate { my $self = shift;
    my $pkg = shift;
    my $name = shift;
    my $retree = shift;
    # $_[0] is now ref to a $trystate;

    $self->deb("cursor_fate $pkg $name") if DEBUG & DEBUG::cursors;
    my $key = refaddr($retree->{$name}) // $name;

    my $lexer = $::LEXERS{ref $self}->{$key} // do {
        local %::AUTOLEXED;
        $self->_AUTOLEXpeek($name,$retree);
    };
    if ($self->{_pos} >= $::HIGHWATER) {
        if ($self->{_pos} > $::HIGHWATER) {
            %$::HIGHEXPECT = ();
            $::HIGHMESS = '';
        }
        $::HIGHEXPECT->{$lexer->{DBA}}++;
        $::HIGHWATER = $self->{_pos};
    }

    my $P = $self->{_pos};
    if ($P > @::ORIG) {
        return sub {};
    }

    $self->cursor_fate_dfa($pkg, $name, $lexer, $P);
}

sub cursor_fate_dfa {
    my ($self, $pkg, $name, $lexer, $P) = @_;

    my $state = $lexer->{S};
    my $p = $P;
    my @rfates;

    print ::LOG "=" x 10,"\n$p DFA for ${pkg}::$name in ", ref $self, "\n" if DEBUG & DEBUG::autolexer;
    CH: {
        push @rfates, @{ $state->[0] // _jit_dfa_node($lexer, $state) };
        if (DEBUG & DEBUG::autolexer) {
            for (@{ $state->[0] }) {
                my @b;
                for (my $f = $_; $f; $f = $f->[0]) {
                    push @b, @{$f}[1,2];
                }
                print ::LOG "    [adding fate @b]\n";
            }
        }
        last if $p == @::ORIG;
        my $chi = $::ORIG[$p++];
        print ::LOG "--- ", pack("U", $chi), "\n" if DEBUG & DEBUG::autolexer;
        if ($state->[1]{$chi}) {
            $state = $state->[1]{$chi};
            print ::LOG "specific -> ", $state->[1]{ID}, "\n"
                if DEBUG & DEBUG::autolexer;
            redo;
        }

        my $dt = $state->[2];
        while (defined $dt) {
            if (ref $dt eq 'ARRAY') {
                if (DEBUG & DEBUG::autolexer) {
                    print ::LOG $dt->[2][-1],
                        (vec($dt->[2][$chi >> 10], $chi & 1023, 1) ?
                            "? yes\n" : "? no\n");
                }
                $dt = $dt->[vec($dt->[2][$chi >> 10], $chi & 1023, 1)];
            } else {
                print ::LOG " -> ", $$dt->[1]{ID}, "\n" if DEBUG & DEBUG::autolexer;
                $state = $state->[1]{$chi} = $$dt;
                redo CH;
            }
        }
    }

    sub { @rfates ? pop(@rfates) : () };
}

sub cursor_all { my $self = shift;
    my $fpos = shift;
    my $tpos = shift;

    $self->deb("cursor_all from $fpos to $tpos") if DEBUG & DEBUG::cursors;
    my %r = %$self;
    @r{'_from','_pos'} = ($fpos,$tpos);

    bless \%r, ref $self;
}

sub makestr { my $self = shift;
    $self->deb("maketext @_") if DEBUG & DEBUG::cursors;
    my %r = @_;

    bless \%r, "Str";
}

sub cursor_tweak { my $self = shift;
    my $tpos = shift;

    if (DEBUG & DEBUG::cursors) {
        my $peek = substr($::ORIG,$tpos,20);
        $peek =~ s/\n/\\n/g;
        $peek =~ s/\t/\\t/g;
        $self->deb("cursor to $tpos --------->$GREEN$peek$CLEAR");
    }
    $self->{_pos} = $tpos;
    return () if $tpos > @::ORIG;

    $self;
}

sub cursor_incr { my $self = shift;
    my $tpos = $self->{_pos} + 1;

    $self->panic("Unexpected EOF") if $tpos > length($::ORIG);
    if (DEBUG & DEBUG::cursors) {
        my $peek = substr($::ORIG,$tpos,20);
        $peek =~ s/\n/\\n/g;
        $peek =~ s/\t/\\t/g;
        $self->deb("cursor to $tpos --------->$GREEN$peek$CLEAR");
    }
    $self->{_pos} = $tpos;
    return () if $tpos > @::ORIG;

    $self;
}

sub cursor { my $self = shift;
    my $tpos = shift;

    $self->panic("Unexpected EOF") if $tpos > length($::ORIG);
    if (DEBUG & DEBUG::cursors) {
        my $peek = substr($::ORIG,$tpos,20);
        $peek =~ s/\n/\\n/g;
        $peek =~ s/\t/\\t/g;
        $self->deb("cursor to $tpos --------->$GREEN$peek$CLEAR");
    }
    my %r = %$self;
#    $r{_from} = $self->{_pos} // 0;
    $r{_pos} = $tpos;

    bless \%r, ref $self;
}

sub cursor_force { my $self = shift;
    my $tpos = shift;

    $self->panic("Unexpected EOF") if $tpos > length($::ORIG);
    if (DEBUG & DEBUG::cursors) {
        my $peek = substr($::ORIG,$tpos,20);
        $peek =~ s/\n/\\n/g;
        $peek =~ s/\t/\\t/g;
        $self->deb("cursor to $tpos --------->$GREEN$peek$CLEAR");
    }
    my %r = %$self;
#    $r{_from} = $self->{_pos} // 0;
    $r{_pos} = $::HIGHWATER = $tpos;

    bless \%r, ref $self;
}

sub cursor_rev { my $self = shift;
    my $fpos = shift;

    if (DEBUG & DEBUG::cursors) {
        my $peek = substr($::ORIG,$fpos,20);
        $peek =~ s/\n/\\n/g;
        $peek =~ s/\t/\\t/g;
        $self->deb("cursor_ref to $fpos --------->$GREEN$peek$CLEAR");
    }
    my %r = %$self;
    $r{_pos} = $fpos;

    bless \%r, ref $self;
}

#############################################################
# Regex service routines
#############################################################

sub callm { my $self = shift;
    my $arg = shift;
    my $class = ref($self) || $self;

    my $lvl = 0;
    my $extralvl = 0;
    my @subs;
    if (DEBUG & DEBUG::callm_show_subnames) {
        while (my @c = caller($lvl)) {
            $lvl++;
            my $s = $c[3];
            if ($s =~ /::_/) {
                next;
            }
            elsif ($s =~ /^(?:STD::Cursor|CursorBase)?::/) {
                next;
            }
            elsif ($s =~ /^STD::LazyMap::/) {
                next;
            }
            elsif ($s =~ /^\(eval\)/) {
                next;
            }
            else {
                $extralvl = $lvl unless $extralvl;
                $s =~ s/.*:://;
                push @subs, $s;
            }
        }
    }
    else {
        while (my @c = caller($lvl)) { $lvl++; }
    }
    my ($package, $file, $line, $subname, $hasargs) = caller(1);
    my $name = $subname;
    if (defined $arg) { 
        $name .= " " . $arg;
    }
    my $pos = '?';
    $self->deb($name, " [", $file, ":", $line, "] $class") if DEBUG & DEBUG::trace_call;
    if (DEBUG & DEBUG::callm_show_subnames) {
        $RED . join(' ', reverse @subs) . $CLEAR . ':' x $extralvl;
    }
    else {
        ':' x $lvl;
    }
}

sub retm {
    return $_[0] unless DEBUG & DEBUG::trace_call;
    my $self = shift;
    warn "Returning non-STD::Cursor: $self\n" unless exists $self->{_pos};
    my ($package, $file, $line, $subname, $hasargs) = caller(1);
    $self->deb($subname, " returning @{[$self->{_pos}]}");
    $self;
}

sub _MATCHIFY { my $self = shift;
    my $S = shift;
    my $name = shift;
    return () unless @_;
    my $xact = $self->{_xact};
    my @result = lazymap( sub { my $x = shift; $x->{_xact} = $xact; $x->_REDUCE($S, $name)->retm() }, @_);
    if (wantarray) {
        @result;
    }
    else {
        $result[0];
    }
}

sub _MATCHIFYr { my $self = shift;
    my $S = shift;
    my $name = shift;
    return () unless @_;
    my $var = shift;
#    $var->{_from} = $self->{_from};
    my $xact = $self->{_xact};
    $var->{_xact} = $xact;
    $var->_REDUCE($S, $name)->retm();
}

sub _SCANf { my $self = shift;

    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $eos = @::ORIG;

    my $pos = $self->{_pos};
    my $C = $self->cursor_xact("SCANf $pos");
    my $xact = $C->xact;

    lazymap( sub { $self->cursor($_[0])->retm() }, STD::LazyRange->new($xact, $pos,$eos) );
}

sub _SCANg { my $self = shift;

    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $pos = $self->{_pos};
    my $eos = @::ORIG;
    my $C = $self->cursor_xact("SCANg $pos");
    my $xact = $C->xact;

    lazymap( sub { $C->cursor($_[0])->retm() }, STD::LazyRangeRev->new($xact, $eos,$pos) );
}

sub _STARf { my $self = shift;
    my $block = shift;
    no warnings 'recursion';

    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;

    my $pos = $self->{_pos};
    my $C = $self->cursor_xact("SCANf $pos");
    my $xact = $C->xact;

    lazymap(sub { $_[0]->retm() }, 
        $C->cursor($pos),
        STD::LazyMap->new(sub { $C->_PLUSf($_[0]) }, $block));
}

sub _STARg { my $self = shift;
    my $block = shift;
    no warnings 'recursion';

    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;

    my $pos = $self->{_pos};
    my $C = $self->cursor_xact("STARg $pos");
#    my $xact = $C->xact;

    lazymap(sub { $_[0]->retm() }, reverse
        eager(
            $C->cursor($self->{_pos}),
            $C->_PLUSf($block))
        );
}

sub _STARr { my $self = shift;
    my $block = shift;
    no warnings 'recursion';

    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $pos = $self->{_pos};
    my $prev = $self->cursor_xact("STARr $pos");
#    my $xact = $prev->xact;

    my $prev_pos = $prev->{_pos} // 0;
    my @all;
    my $eos = @::ORIG;

    for (;;) {
      last if $prev->{_pos} == $eos;
        my @matches = $block->($prev);  # XXX shouldn't read whole list
#            say @matches.perl;
      last unless @matches;
        my $first = $matches[0];  # no backtracking into block on ratchet
        last if $first->{_pos} == $prev_pos;
        $prev_pos = $first->{_pos};
        push @all, $first;
        $prev = $first;
    }
    $self->cursor($prev_pos)->retm();
}

sub _PLUSf { my $self = shift;
    my $block = shift;
    no warnings 'recursion';

    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;

    my $pos = $self->{_pos};
    my $x = $self->cursor_xact("PLUSf $pos");
    my $xact = $x->xact;

    # don't go beyond end of string
    return () if $self->{_pos} == @::ORIG;

    lazymap(
        sub {
            my $x = $_[0];
            lazymap(
                sub {
                    $self->cursor($_[0]->{_pos})->retm()
                }, $x, STD::LazyMap->new(sub { $x->_PLUSf($_[0]) }, $block)
            );
        }, $block->($self)
    );
}

sub _PLUSg { my $self = shift;
    my $block = shift;
    no warnings 'recursion';

    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;

    my $pos = $self->{_pos};
    my $C = $self->cursor_xact("PLUSg $pos");
#    my $xact = $C->xact;

    reverse eager($C->_PLUSf($block, @_));
}

sub _PLUSr { my $self = shift;
    my $block = shift;
    no warnings 'recursion';

    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my @all;
    my $eos = @::ORIG;

    my $pos = $self->{_pos};
    my $to = $self->cursor_xact("PLUSr $pos");
#    my $xact = $to->xact;

    for (;;) {
      last if $to->{_pos} == $eos;
        my @matches = $block->($to);  # XXX shouldn't read whole list
      last unless @matches;
        my $first = $matches[0];  # no backtracking into block on ratchet
        #$first->deb($matches->perl) if DEBUG;
        push @all, $first;
        $to = $first;
    }
    return () unless @all;
    $self->cursor($to->{_pos})->retm();
}

sub _REPSEPf { my $self = shift;
    my $sep = shift;
    my $block = shift;
    no warnings 'recursion';

    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;

    my @result;
    # don't go beyond end of string
    return () if $self->{_pos} == @::ORIG;

    my $pos = $self->{_pos};
    my $C = $self->cursor_xact("REPSEPf $pos");
#    my $xact = $C->xact;

    do {
        for my $x ($block->($C)) {
            for my $s ($sep->($x)) {
                push @result, lazymap(sub { $C->cursor($_[0]->{_pos}) }, $x, $s->_REPSEPf($sep,$block));
            }
        }
    };
    lazymap(sub { $_[0]->retm() }, @result);
}

sub _REPSEPg { my $self = shift;
    my $sep = shift;
    my $block = shift;
    no warnings 'recursion';

    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;

    my $pos = $self->{_pos};
    my $C = $self->cursor_xact("REPSEPg $pos");
    # my $xact = $C->xact;

    reverse eager($C->_REPSEPf($sep, $block, @_));
}

sub _REPSEPr { my $self = shift;
    my $sep = shift;
    my $block = shift;
    no warnings 'recursion';

    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my @all;
    my $eos = @::ORIG;

    my $pos = $self->{_pos};
    my $to = $self->cursor_xact("REPSEPr $pos");
#    my $xact = $C->xact;

    for (;;) {
      last if $to->{_pos} == $eos;
        my @matches = $block->($to);  # XXX shouldn't read whole list
      last unless @matches;
        my $first = $matches[0];  # no backtracking into block on ratchet
        #$first->deb($matches->perl) if DEBUG;
        push @all, $first;
        my @seps = $sep->($first);
      last unless @seps;
        my $sep = $seps[0];
        $to = $sep;
    }
    return () unless @all;
    $self->cursor($all[-1]->{_pos})->retm;
}

sub _OPTr { my $self = shift;
    my $block = shift;
    no warnings 'recursion';

    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;

    my $pos = $self->{_pos};
    my $C = $self->cursor_xact("OPTr $pos");
    my $xact = $C->xact;

    my $x = ($block->($C))[0];
    my $r = $x // $C->cursor_tweak($pos);
    $r->{_xact} = $self->{_xact};
    $r->retm();
}

sub _OPTg { my $self = shift;
    my $block = shift;
    no warnings 'recursion';

    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;

    my $pos = $self->{_pos};
    my $C = $self->cursor_xact("OPTg $pos");
#    my $xact = $C->xact;

    my @x = $block->($C);

    lazymap(sub { $_[0]->retm() },
        $block->($C),
        $self->cursor($pos));
}

sub _OPTf { my $self = shift;
    my $block = shift;
    no warnings 'recursion';

    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;

    my $pos = $self->{_pos};
    my $C = $self->cursor_xact("OPTf $pos");
#    my $xact = $C->xact;

    lazymap(sub { $_[0]->retm() },
        $C->cursor($C->{_pos}),
        $block->($self));
}

sub _BRACKET { my $self = shift;
    my $block = shift;
    no warnings 'recursion';

    my $oldlang = ref($self);
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    lazymap(sub { bless($_[0],$oldlang)->retm() },
        $block->($self));
}

sub _BRACKETr { my $self = shift;
    my $block = shift;
    no warnings 'recursion';

    my $oldlang = ref($self);
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my ($val) = $block->($self) or return ();
    bless($val,$oldlang)->retm();
}

sub _PAREN { my $self = shift;
    my $block = shift;
    no warnings 'recursion';

    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    lazymap(sub { $_[0]->retm() },
        $block->($self));
}

sub _NOTBEFORE { my $self = shift;
    my $block = shift;
    no warnings 'recursion';

    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    local $::HIGHEXPECT = {};   # don't count lookahead as expectation
    local $::HIGHWATER = $::HIGHWATER;
    my @caps;
    @caps = @{$self->{'~CAPS'}} if $self->{'~CAPS'};  # must copy elems
    my @all = $block->($self);
    return () if @all;
    $self->{'~CAPS'} = \@caps;
    return $self->cursor($self->{_pos})->retm();
}

sub _NOTCHAR { my $self = shift;
    my $block = shift;
    no warnings 'recursion';

    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my @all = $block->($self);
    return () if @all;
    return $self->cursor($self->{_pos}+1)->retm();
}

sub before { my $self = shift;
    my $block = shift;
    no warnings 'recursion';

    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    local $::HIGHEXPECT = {};   # don't count lookahead as expectation
    local $::HIGHWATER = $::HIGHWATER;
    my @caps;
    @caps = @{$self->{'~CAPS'}} if $self->{'~CAPS'};  # must copy elems
    my @all = $block->($self);
    if (@all and $all[0]) {
        $all[0]->{'~CAPS'} = \@caps;
        if ($self->{_ast}) {
            $all[0]->{'_ast'} = $self->{_ast};
        }
        else {
            delete $all[0]->{'_ast'};
        }
        return $all[0]->cursor_all(($self->{_pos}) x 2)->retm();
    }
    return ();
}

sub suppose { my $self = shift;
    my $block = shift;
    no warnings 'recursion';

    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    local $::FATALS = 0;
    local @::WORRIES;
    local %::WORRIES;
    local $::HIGHWATER = -1;
    local $::HIGHMESS;
    local $::HIGHEXPECT = {};
    local $::IN_SUPPOSE = 1;
    my @all;
    eval {
        @all = $block->($self);
    };
    lazymap( sub { $_[0]->retm() }, @all );
}

sub after { my $self = shift;
    my $block = shift;
    no warnings 'recursion';

    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    local $::HIGHEXPECT = {};   # don't count lookbehind as expectation
    my $end = $self->cursor($self->{_pos});
    my @caps;
    @caps = @{$self->{'~CAPS'}} if $self->{'~CAPS'};  # must copy elems
    my @all = $block->($end);          # Make sure $_->{_from} == $_->{_pos}
    if (@all and $all[0]) {
        $all[0]->{'~CAPS'} = \@caps;
        if ($self->{_ast}) {
            $all[0]->{'_ast'} = $self->{_ast};
        }
        else {
            delete $all[0]->{'_ast'};
        }
        return $all[0]->cursor_all(($self->{_pos}) x 2)->retm();
    }
    return ();
}

sub null { my $self = shift;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    return $self->cursor($self->{_pos})->retm();
}

sub ws__PEEK { ''; }
sub ws {
    my $self = shift;

    local $CTX = $self->callm() if DEBUG & DEBUG::trace_call;
    my @stub = return $self if exists $::MEMOS[$self->{_pos}]{ws};

    my $S = $self->{_pos};
    my $C = $self->cursor_xact("RULE ws $S");
#    my $xact = $C->xact;

    $::MEMOS[$S]{ws} = undef;   # exists means we know, undef means no ws  before here

    $self->_MATCHIFY($S, 'ws',
        $C->_BRACKET( sub { my $C=shift;
            do { my @gather;
                    push @gather, (map { my $C=$_;
                        (map { my $C=$_;
                            (map { my $C=$_;
                                $C->_NOTBEFORE( sub { my $C=shift;
                                    $C
                                })
                            } $C->_COMMITRULE())
                        } $C->before(sub { my $C=shift;
                            $C->_ALNUM()
                        }))
                    } $C->before( sub { my $C=shift;
                        $C->after(sub { my $C=shift;
                            $C->_ALNUM_rev()
                        })
                    }))
                    or
                    push @gather, (map { my $C=$_;
                        (map { my $C=$_;
                            scalar(do { $::MEMOS[$C->{_pos}]{ws} = $S unless $C->{_pos} == $S }, $C)
                        } $C->_STARr(sub { my $C=shift;
                            $C->_SPACE()
                        }))
                    } $C);
              @gather;
            }
        })
    );
}

sub _ASSERT { my $self = shift;
    my $block = shift;
    no warnings 'recursion';

    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my @all = $block->($self);
    if ((@all and $all[0]->{_bool})) {
        return $self->cursor($self->{_pos})->retm();
    }
    return ();
}

sub _BINDVAR { my $self = shift;
    my $var = shift;
    my $block = shift;
    no warnings 'recursion';

    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    lazymap(sub { $$var = $_[0]; $_[0]->retm() },
        $block->($self));
}

sub _SUBSUME { my $self = shift;
    my $names = shift;
    my $block = shift;
    no warnings 'recursion';
    no warnings 'recursion';

    local $CTX = $self->callm($names ? "@$names" : "") if DEBUG & DEBUG::trace_call;
    lazymap(sub { $self->cursor_bind($names, $_[0])->retm() },
        $block->($self->cursor_fresh()));
}

sub _SUBSUMEr { my $self = shift;
    my $names = shift;
    my $block = shift;
    no warnings 'recursion';
    no warnings 'recursion';

    local $CTX = $self->callm($names ? "@$names" : "") if DEBUG & DEBUG::trace_call;
    my ($var) = $block->($self->cursor_fresh()) or return ();
    $self->cursor_bind($names, $var)->retm();
}

sub _EXACT_rev { my $self = shift;
    my $s = shift() // '';
    my @ints = unpack("U*", $s);

    local $CTX = $self->callm($s) if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos} // 0;
    while (@ints) {
        return () unless ($::ORIG[--$P]//-1) == pop @ints;
    }
    return $self->cursor($P)->retm();
}

sub _EXACT { my $self = shift;
    my $s = shift() // '';
    my @ints = unpack("U*", $s);

    local $CTX = $self->callm($s) if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos} // 0;
    while (@ints) {
        return () unless ($::ORIG[$P++]//-1) == shift @ints;
    }
    return $self->cursor($P)->retm();
#    if (substr($::ORIG, $P, $len) eq $s) {
#        $self->deb("EXACT $s matched @{[substr($::ORIG,$P,$len)]} at $P $len") if DEBUG & DEBUG::matchers;
#        my $r = $self->cursor($P+$len);
#        $r->retm();
#    }
#    else {
#        $self->deb("EXACT $s didn't match @{[substr($::ORIG,$P,$len)]} at $P $len") if DEBUG & DEBUG::matchers;
#        return ();
#    }
}

sub _PATTERN { my $self = shift;
    my $qr = shift;

    local $CTX = $self->callm($qr) if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos} // 0;
    pos($::ORIG) = $P;
    if ($::ORIG =~ /$qr/gc) {
        my $len = pos($::ORIG) - $P;
        $self->deb("PATTERN $qr matched @{[substr($::ORIG,$P,$len)]} at $P $len") if DEBUG & DEBUG::matchers;
        my $r = $self->cursor($P+$len);
        $r->retm();
    }
    else {
        $self->deb("PATTERN $qr didn't match at $P") if DEBUG & DEBUG::matchers;
        return ();
    }
}

sub _BACKREFn { my $self = shift;
    my $n = shift;

    local $CTX = $self->callm($n) if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos} // 0;
    my $s = $self->{$n}->Str;
    my $len = length($s);
    if (substr($::ORIG, $P, $len) eq $s) {
        $self->deb("EXACT $s matched @{[substr($::ORIG,$P,$len)]} at $P $len") if DEBUG & DEBUG::matchers;
        my $r = $self->cursor($P+$len);
        $r->retm();
    }
    else {
        $self->deb("EXACT $s didn't match @{[substr($::ORIG,$P,$len)]} at $P $len") if DEBUG & DEBUG::matchers;
        return ();
    }
}

sub _SYM { my $self = shift;
    my $s = shift;
    my $i = shift;

    $s = $s->[0] if ref $s eq 'ARRAY';

    local $CTX = $self->callm($s) if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos} // 0;
    my $len = length($s);
    if ($i
        ? lc substr($::ORIG, $P, $len) eq lc $s
        : substr($::ORIG, $P, $len) eq $s
    ) {
        $self->deb("SYM $s matched @{[substr($::ORIG,$P,$len)]} at $P $len") if DEBUG & DEBUG::matchers;
        my $r = $self->cursor($P+$len);
        $r->{sym} = $s;
        $r->retm();
    }
    else {
        $self->deb("SYM $s didn't match @{[substr($::ORIG,$P,$len)]} at $P $len") if DEBUG & DEBUG::matchers;
        return ();
    }
}

#sub _EXACT_rev { my $self = shift;
#    my $s = shift;
#
#    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
#    my $len = length($s);
#    my $from = $self->{_pos} - $len;
#    if ($from >= 0 and substr($::ORIG, $from, $len) eq $s) {
#        my $r = $self->cursor_rev($from);
#        $r->retm();
#    }
#    else {
##        say "EXACT_rev $s didn't match @{[substr($!orig,$from,$len)]} at $from $len";
#        return ();
#    }
#}

sub _ARRAY { my $self = shift;
    local $CTX = $self->callm(0+@_) if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos} // 0;
    my @array = sort { length($b) <=> length($a) } @_;  # XXX suboptimal
    my @result = ();
    for my $s (@array) {
        my $len = length($s);
        if (substr($::ORIG, $P, $len) eq $s) {
            $self->deb("ARRAY elem $s matched @{[substr($::ORIG,$P,$len)]} at $P $len") if DEBUG & DEBUG::matchers;
            my $r = $self->cursor($P+$len);
            push @result, $r->retm('');
        }
    }
    return @result;
}

sub _ARRAY_rev { my $self = shift;
    local $CTX = $self->callm(0+@_) if DEBUG & DEBUG::trace_call;
    my @array = sort { length($b) <=> length($a) } @_;  # XXX suboptimal
    my @result = ();
    for my $s (@array) {
        my $len = length($s);
        my $from = $self->{_pos} = $len;
        if (substr($::ORIG, $from, $len) eq $s) {
            $self->deb("ARRAY_rev elem $s matched @{[substr($::ORIG,$from,$len)]} at $from $len") if DEBUG & DEBUG::matchers;
            my $r = $self->cursor_rev($from);
            push @result, $r->retm('');
        }
    }
    return @result;
}

sub _DIGIT { my $self = shift;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos};
    my $char = substr($::ORIG, $P, 1);
    if ($char =~ /^\d$/) {
        my $r = $self->cursor($P+1);
        return $r->retm();
    }
    else {
#        say "DIGIT didn't match $char at $P";
        return ();
    }
}

sub _DIGIT_rev { my $self = shift;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $from = $self->{_pos} - 1;
    if ($from < 0) {
#        say "DIGIT_rev didn't match $char at $from";
        return ();
    }
    my $char = substr($::ORIG, $from, 1);
    if ($char =~ /^\d$/) {
        my $r = $self->cursor_rev($from);
        return $r->retm();
    }
    else {
#        say "DIGIT_rev didn't match $char at $from";
        return ();
    }
}

sub ww { my $self = shift;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos};
    return () unless $P;
    my $chars = substr($::ORIG, $P-1, 2);
    if ($chars =~ /^\w\w$/) {
        my $r = $self->cursor($P);
        return $r->retm();
    }
    else {
#        say "ww didn't match $chars at $P";
        return ();
    }
}

sub _ALNUM { my $self = shift;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos};
    my $char = substr($::ORIG, $P, 1);
    if ($char =~ /^\w$/) {
        my $r = $self->cursor($P+1);
        return $r->retm();
    }
    else {
#        say "ALNUM didn't match $char at $P";
        return ();
    }
}

sub _ALNUM_rev { my $self = shift;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $from = $self->{_pos} - 1;
    if ($from < 0) {
#        say "ALNUM_rev didn't match $char at $from";
        return ();
    }
    my $char = substr($::ORIG, $from, 1);
    if ($char =~ /^\w$/) {
        my $r = $self->cursor_rev($from);
        return $r->retm();
    }
    else {
#        say "ALNUM_rev didn't match $char at $from";
        return ();
    }
}

my $alpha;
BEGIN {
    $alpha = "";
    for my $ch (0..255) {
        my $char = chr($ch);
        vec($alpha,$ch,1) = 1 if $char =~ /\w/ and $char !~ /\d/;
    }
}
sub alpha { my $self = shift;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos};
#    my $char = substr($::ORIG, $P, 1);
    my $ch = $::ORIG[$P];
    if (vec($alpha,$ch,1) or ($ch > 255 and chr($ch) =~ /\pL/)) {
#    if ($char =~ /^[_[:alpha:]\pL]$/) {
        my $r = $self->cursor($P+1);
        return $r->retm();
    }
    else {
#        say "alpha didn't match $char at $P";
        return ();
    }
}

sub alpha_rev { my $self = shift;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $from = $self->{_pos} - 1;
    if ($from < 0) {
        return ();
    }
    my $char = substr($::ORIG, $from, 1);
    if ($char =~ /^[_[:alpha:]\pL]$/) {
        my $r = $self->cursor_rev($from);
        return $r->retm();
    }
    else {
        return ();
    }
}

sub _SPACE { my $self = shift;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos};
    my $char = substr($::ORIG, $P, 1);
    if ($char =~ /^\s$/) {
        my $r = $self->cursor($P+1);
        return $r->retm();
    }
    else {
#        say "SPACE didn't match $char at $P";
        return ();
    }
}

sub _SPACE_rev { my $self = shift;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $from = $self->{_pos} - 1;
    if ($from < 0) {
#        say "SPACE_rev didn't match $char at $from";
        return ();
    }
    my $char = substr($::ORIG, $from, 1);
    if ($char =~ /^\s$/) {
        my $r = $self->cursor_rev($from);
        return $r->retm();
    }
    else {
#        say "SPACE_rev didn't match $char at $from";
        return ();
    }
}

sub _HSPACE { my $self = shift;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos};
    my $char = substr($::ORIG, $P, 1);
    if ($char =~ /^[ \t\r]$/ or ($char =~ /^\s$/ and $char !~ /^[\n\f\0x0b\x{2028}\x{2029}]$/)) {
        my $r = $self->cursor($P+1);
        return $r->retm();
    }
    else {
#        say "HSPACE didn't match $char at $P";
        return ();
    }
}

sub _HSPACE_rev { my $self = shift;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $from = $self->{_pos} - 1;
    if ($from < 0) {
#        say "HSPACE_rev didn't match $char at $from";
        return ();
    }
    my $char = substr($::ORIG, $from, 1);
    if ($char =~ /^[ \t\r]$/ or ($char =~ /^\s$/ and $char !~ /^[\n\f\0x0b\x{2028}\x{2029}]$/)) {
        my $r = $self->cursor_rev($from);
        return $r->retm();
    }
    else {
#        say "HSPACE_rev didn't match $char at $from";
        return ();
    }
}

sub _VSPACE { my $self = shift;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos};
    my $char = substr($::ORIG, $P, 1);
    if ($char =~ /^[\n\f\x0b\x{2028}\x{2029}]$/) {
        my $r = $self->cursor($P+1);
        return $r->retm();
    }
    else {
#        say "VSPACE didn't match $char at $P";
        return ();
    }
}

sub _VSPACE_rev { my $self = shift;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $from = $self->{_pos} - 1;
    if ($from < 0) {
#        say "VSPACE_rev didn't match $char at $from";
        return ();
    }
    my $char = substr($::ORIG, $from, 1);
    if ($char =~ /^[\n\f\x0b\x{2028}\x{2029}]$/) {
        my $r = $self->cursor_rev($from);
        return $r->retm();
    }
    else {
#        say "VSPACE_rev didn't match $char at $from";
        return ();
    }
}

sub _CCLASS { my $self = shift;
    my $cc = shift;

    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos};
    my $char = substr($::ORIG, $P, 1);
    if ($char =~ /$cc/) {
        my $r = $self->cursor($P+1);
        return $r->retm();
    }
    else {
#        say "CCLASS didn't match $char at $P";
        return ();
    }
}

sub _CCLASS_rev { my $self = shift;
    my $cc = shift;

    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $from = $self->{_pos} - 1;
    if ($from < 0) {
#        say "CCLASS didn't match $char at $from";
        return ();
    }
    my $char = substr($::ORIG, $from, 1);
    if ($char =~ /$cc/) {
        my $r = $self->cursor_rev($from);
        return $r->retm();
    }
    else {
#        say "CCLASS didn't match $char at $from";
        return ();
    }
}

sub _ANY { my $self = shift;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos};
    if ($P < @::ORIG) {
        $self->cursor($P+1)->retm();
    }
    else {
#        say "ANY didn't match anything at $P";
        return ();
    }
}

sub _ANY_rev { my $self = shift;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $from = $self->{_pos} - 1;
    if ($from < 0) {
        return ();
    }
    return $self->cursor_rev($from)->retm();
}

sub _BOS { my $self = shift;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos};
    if ($P == 0) {
        $self->cursor($P)->retm();
    }
    else {
        return ();
    }
}
sub _BOS_rev { $_[0]->_BOS }

sub _BOL { my $self = shift;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos};
    if ($P == 0 or substr($::ORIG, $P-1, 1) =~ /^[\n\f\x0b\x{2028}\x{2029}]$/) {
        $self->cursor($P)->retm();
    }
    else {
        return ();
    }
}
sub _BOL_rev { $_[0]->_BOL }

sub _EOS { my $self = shift;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos};
    if ($P == @::ORIG) {
        $self->cursor($P)->retm();
    }
    else {
        return ();
    }
}
sub _EOS_rev { $_[0]->_EOS }

sub _EOL { my $self = shift;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos};
    if ($P == @::ORIG or substr($::ORIG, $P, 1) =~ /^(?:\r\n|[\n\f\x0b\x{2028}\x{2029}])$/) {
        $self->cursor($P)->retm();
    }
    else {
        return ();
    }
}
sub _EOL_rev { $_[0]->_EOL }

sub _RIGHTWB { my $self = shift;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos};
    pos($::ORIG) = $P - 1;
    if ($::ORIG =~ /\w\b/) {
        $self->cursor($P)->retm();
    }
    else {
        return ();
    }
}
sub _RIGHTWB_rev { $_[0]->_RIGHTWB }

sub _LEFTWB { my $self = shift;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos};
    pos($::ORIG) = $P;
    if ($::ORIG =~ /\b(?=\w)/) {
        $self->cursor($P)->retm();
    }
    else {
        return ();
    }
}
sub _LEFTWB_rev { $_[0]->_LEFTWB }

sub _LEFTRESULT { my $self = shift;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos};
    pos($::ORIG) = $P;
    if ($::ORIG =~ /\b(?=\w)/) {
        $self->cursor($P)->retm();
    }
    else {
        return ();
    }
}
sub _LEFTRESULT_rev { $_[0]->_LEFTWB }

sub _REDUCE { my $self = shift;
    my $S = shift;
    my $meth = shift;
    my $key = $meth;
    $key .= ' ' . $_[0] if @_;

    $self->{_reduced} = $key;
    $self->{_from} = $S;
    if ($::ACTIONS) {
        eval { $::ACTIONS->$meth($self, @_) };
        warn $@ if $@ and not $@ =~ /locate object method "\Q$meth/;
    }
    $self->deb("REDUCE $key from " . $S . " to " . $self->{_pos}) if DEBUG & DEBUG::matchers;
    $self;
}

sub _COMMITBRANCH { my $self = shift;
    my $xact = $self->xact;
#    $self->{LAST} = shift() if @_;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos};
    while ($xact) {
        $xact->[-2] = 1;
        $self->deb("Commit $$xact[0] to $P") if DEBUG & DEBUG::matchers;
        return $self->cursor_xact("CB") if $xact->[0] =~ /^ALT/;
        $xact = $xact->[-1];
    }
    die "Not in an alternation, so can't commit to a branch";
}

sub _COMMITLTM { my $self = shift;
    my $xact = $self->xact;
#    $self->{LAST} = shift() if @_;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos};
    while ($xact) {
        $xact->[-2] = 1;
        $self->deb("Commit $$xact[0] to $P") if DEBUG & DEBUG::matchers;
        return $self->cursor_xact("CL") if $xact->[0] =~ /^ALTLTM/;
        $xact = $xact->[-1];
    }
    die "Not in a longest token matcher, so can't commit to a longest token";
}

sub _COMMITRULE { my $self = shift;
    my $xact = $self->xact;
#    $self->{LAST} = shift() if @_;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos};
    while ($xact) {
        $xact->[-2] = 1;
        $self->deb("Commit $$xact[0] to $P") if DEBUG & DEBUG::matchers;
        return $self->cursor_xact("CR") if $xact->[0] =~ /^RULE/;
        $xact = $xact->[-1];
    }
    die "Not in a rule, so can't commit to rule";
}

sub commit { my $self = shift;
    my $xact = $self->xact;
#    $self->{LAST} = shift() if @_;
    local $CTX = $self->callm if DEBUG & DEBUG::trace_call;
    my $P = $self->{_pos};
    while ($xact) {
        $xact->[-2] = 1;
        $self->deb("Commit $$xact[0] to $P") if DEBUG & DEBUG::matchers;
        return $self->cursor_xact("CM") if $xact->[0] =~ /^MATCH/;
        $xact = $xact->[-1];
    }
    die "Not in a match, so can't commit to match";
}

sub fail { my $self = shift;
    my $m = shift;
    return ();
}

sub bless { CORE::bless $_[1], $_[0]->WHAT }

#############################################################
# JIT lexer generator
#############################################################

## NFA structure:
##   array of (NFA node) ->
##     0: non extensible (imperative) flag
##     0: array of fate (array of fate element)
##     array of (label) at odd index, new index at even
## DFA structure:
##   each DFA node is array:
##     0: array of object fates
##     1: hash of specific cases (char => DFAnode)
##        also carries some debug data
##    2n: reference to a uniprop hash
##  2n+1: DFAnode is that hash existed
## Labels: undef is epsilon link.
##   otherwise list - 1 positive, 0+ negative
##   each is: 1 character, else unicode prop in "Gc/L" form
## "DFA" lexer structure:
##   {DFA} -> array of refs to all DFA nodes
##   {DBA}, {FILE}, {NAME} same as "RE" lexer structure
##   {S} -> ref to DFA root
##   {NFA} -> NFA structure
## individual fates in the NFA end with a hook which can be 1 to stop adding
## fates on the end; it's not always possible to associate a unique fate with
## each NFA node, consider (a|b)*
## A NFA or DFA node is accepting if it has a nonempty list of fates

#cycle breaker
{
    package CursorBase::dfa;
    sub DESTROY {
        my $self = shift;
        for (@$self) { @$_ = (); }
    }
}

# Steal data from Perl5's Unicode maps
my %unicode_map_cache;
BEGIN {
    $unicode_map_cache{ALL} = [scalar("\377" x 128) x 1088, "ALL"] ;
    my $name = File::Spec->catfile($data_dir, "uniprops");
    open MAP, "<", "$name" or
        die "cannot open unicode maps from $name : $!\n";

    binmode MAP;
    while (defined (my $c = getc MAP)) {
        my $name = "";
        my $used;
        my $tile;
        read MAP, $name, ord($c);
        read MAP, $used, 136;

        $unicode_map_cache{$name} = [ (("") x 1088), $name ];

        for (my $i = 0; $i < 1088; $i++) {
            if (vec($used, $i, 1)) {
                read MAP, $tile, 128;
                $unicode_map_cache{$name}[$i] = $tile;
            }
        }
    }
    close MAP or die "cannot close unicode maps: $!";
}
sub _get_unicode_map {
    my $propname = shift;
    $unicode_map_cache{$propname} //
        die "Map $propname not found.  Edit gen-unicode-table.pl and rerun.";
}

# This is the fast path handling for JIT DFA lexer generation (although it gets
# short-circuited if the DFALEXERS entry exists, later).  The lexer generation
# process sometimes recurses to this, which is tracked using %::AUTOLEXED; if
# the value is already set, we need to suppress recursion.

our $fakepos = 1;

sub _dump_nfa { my ($name, $nfa) = @_;
    print ::LOG "--- BEGIN NFA DUMP ($name) ---\n";
    for my $ix (0 .. @$nfa-1) {
        my @go;
        for (my $j = 2; $j < @{ $nfa->[$ix] }; $j += 2) {
            push @go, "[" . join("-",@{$nfa->[$ix][$j] // []}) . "] => " . $nfa->[$ix][$j+1];
        }
        my $l = sprintf "%4d: %-30s ", $ix, join(", ", @go);
        if ($nfa->[$ix][1]) {
            my @x = @{ $nfa->[$ix][1] };
            push @x, "..." if shift(@x);
            $l .= join(" ", "-->", @x);
        }
        print ::LOG $l, "\n";
    }
    print ::LOG "---- END NFA DUMP ----\n";
}

sub _dtree_dump { my ($ord, $dt) = @_;
    print ::LOG ("    " x (2 + $ord));
    if (!defined $dt) {
        print ::LOG "END\n";
    } elsif (ref $dt ne 'ARRAY') {
        print ::LOG ($$dt)->[1]{ID}, "\n";
    } else {
        print ::LOG $dt->[2][-1], "?\n";
        _dtree_dump($ord+1, $dt->[1]);
        _dtree_dump($ord+1, $dt->[0]);
    }
}

sub _dfa_dump_node { my ($dfan) = @_;
    my @go;
    my @gor = %{ $dfan->[1] };
    while (my ($a, $b) = splice @gor, 0, 2) {
        next if $a eq 'DESC';
        next if $a eq 'ID';
        push @go, "'" . ::qm(chr $a) . "' => " . $b->[1]{ID};
    }
    printf ::LOG "%-30s %-30s\n", $dfan->[1]{DESC} . ":", join(", ", @go);
    _dtree_dump(0, $dfan->[2]);
    for (@{ $dfan->[0] }) {
        my @arr;
        for (my $fate = $_; $fate; $fate = $fate->[0]) {
            push @arr, $fate->[1], $fate->[2];
        }
        print ::LOG "    --> ", join(" ", @arr), "\n";
    }
}

sub _elem_matches { # my ($char, $element) = @_;
    # Optimize for the common path
    return $_[0] eq $_[1] if length $_[1] == 1;

    my $i = ord $_[0];
    return vec(_get_unicode_map($_[1])->[$i >> 10], $i & 1023, 1);
}

my %boolean_tables = map { $_, 1 } qw/AHex Alpha BidiC BidiM CE CI CWCF CWCM
    CWKCF CWL CWT CWU Cased CompEx DI Dash Dep Dia Ext GrBase GrExt Hex Hyphen
    IDC IDS IDSB IDST Ideo JoinC Lower Math NChar NFDQC OAlpha ODI OGrExt OIDC
    OIDS OLower OMath OUpper PatSyn PatWS QMark Radical SD STerm Space Term
    UIdeo Upper VS XIDC XIDS/;
sub _elem_excludes { my ($up1, $up2) = @_;
    my ($t1, $v1) = split "/", $up1;
    my ($t2, $v2) = split "/", $up2;

    return 0 if $t1 ne $t2;
    return 0 if $v1 eq $v2;

    return 1 if $boolean_tables{$t1};
    return 1 if $t1 eq 'Gc' && (length($v1) == length($v2)
        || substr($v1, 0, 1) ne substr($v2, 0, 1));

    return 0;
}

sub _elem_implies { my ($up1, $up2) = @_;
    my ($t1, $v1) = split "/", $up1;
    my ($t2, $v2) = split "/", $up2;

    return 0 if $t1 ne $t2;
    return 1 if $v1 eq $v2;

    return 1 if $t1 eq 'Gc' && substr($v1, 0, 1) eq $v2;

    return 0;
}

sub _elem_dich { my ($up1, $up2) = @_;
    my ($t1, $v1) = split "/", $up1;
    my ($t2, $v2) = split "/", $up2;

    return 0 if $t1 ne $t2;
    return 0 if $v1 eq $v2;

    return 1 if $boolean_tables{$t1};
    return 0;
}

sub _decision_tree { my ($thunk, @edges) = @_;
    my $branch;

    TERM: for (my $i = 0; $i < @edges; $i += 2) {
        for my $c (@{ $edges[$i] }) {
            next if $c eq 'ALL';
            $branch = $c;
            last TERM;
        }
    }

    if (defined $branch) {
        my @true;
        my @false;

        for (my $i = 0; $i < @edges; $i += 2) {
            my ($p, @n) = @{ $edges[$i] };

            if (!_elem_excludes($branch, $p) &&
                    !(grep { _elem_implies($branch, $_) } @n)) {
                my $pp = _elem_implies($branch, $p) ? 'ALL' : $p;
                my @nn = grep { !_elem_excludes($branch, $_) } @n;
                push @true, [ $pp, @nn ], $edges[$i+1];
            }

            if (!_elem_implies($p, $branch) &&
                    !(grep { _elem_dich($branch, $_) } @n)) {
                my $pp = _elem_dich($branch, $p) ? 'ALL' : $p;
                my @nn = grep { !_elem_implies($_, $branch) } @n;
                push @false, [ $pp, @nn ], $edges[$i+1];
            }
        }

        return [ _decision_tree($thunk, @false),
                 _decision_tree($thunk, @true),
                 _get_unicode_map($branch) ];
    } else {
        # all edges are labelled [ALL]
        my $bm = "";
        for (my $i = 1; $i < @edges; $i += 2) {
            vec($bm, $edges[$i], 1) = 1;
        }
        return ($bm ne '') ? (\ $thunk->($bm)) : undef;
    }
}

sub _tangle_edges { my ($our_edges, $thunk) = @_;
    my %used_chars;
    my %used_cats;

    for (my $i = 0; $i < @$our_edges; $i += 2) {
        next unless $our_edges->[$i];
        for (@{ $our_edges->[$i] }) {
            if (length($_) == 1) {
                $used_chars{$_} = 1;
            } else {
                $used_cats{$_} = 1;
            }
        }
    }

    # First, all specifically mentioned characters are floated to the initial
    # case
    my %next_1;
    my $edgelistref;
    for my $ch (keys %used_chars) {
        my $bm = "";
        EDGE: for (my $i = 0; $i < @$our_edges; $i += 2) {
            $edgelistref = $our_edges->[$i];
            if (length $edgelistref->[0] != 1) {
              my $o = ord $ch; # inlined from _elem_matches
              next unless vec(_get_unicode_map($edgelistref->[0])->[$o >> 10], $o & 1023, 1);
            } elsif ($edgelistref->[0] ne $ch) {
              next;
            }
            my @edgelist = @$edgelistref;
            for (my $j = 0; ++$j < @edgelist; ) {
                next EDGE if _elem_matches($ch, $edgelistref->[$j]);
            }
            vec($bm, $our_edges->[$i+1], 1) = 1;
        }
        $next_1{ord $ch} = $thunk->($bm);
    }

    # Now clean them out so the decision tree engine doesn't have to deal with
    # single characters
    $our_edges = [ @$our_edges ];
    for (my $i = 0; $i < @$our_edges; ) {
        if (!$our_edges->[$i] || length($our_edges->[$i][0]) == 1) {
            splice @$our_edges, $i, 2;
        } else {
            $our_edges->[$i] = [grep { length($_) > 1 } @{ $our_edges->[$i] }];
            $i += 2;
        }
    }

    \%next_1, _decision_tree($thunk, @$our_edges);
}

sub _jit_dfa_node { my ($lexer, $node) = @_;
    my $nfa2dfa = sub { my $nbm = shift;
        $lexer->{NFA2DFA}->{$nbm} //= do {
            my @node;
            $node[1] = { ID => scalar(@{ $lexer->{DFA} }), BITS => $nbm };
            push @{ $lexer->{DFA} }, \@node;
            \@node;
        }
    };

    my $bf = $node->[1]{BITS};
    my $id = $node->[1]{ID};
    my $nfa = $lexer->{NFA};

    my %black;
    my @nfixes = grep { vec($bf, $_, 1) } (0 .. length($bf)*8 - 1);
    my @grey = @nfixes;
    my @ouredges;

    while (@grey) {
        my $nix = pop @grey;
        next if $black{$nix};
        $black{$nix} = 1;
        my $nfn = $nfa->[$nix];

        push @{ $node->[0] }, $nfn->[1] if $nfn->[1];
        for (my $i = 2; $i < @$nfn; $i += 2) {
            if (!$nfn->[$i]) {
                push @grey, $nfn->[$i+1];
            } else {
                push @ouredges, $nfn->[$i], $nfn->[$i+1];
            }
        }
    }

    for my $fate (@{ $node->[0] }) {
        my @a = reverse @$fate;
        my $fo = undef;
        my $tb = "";
        for (my $i = 0; $i < @a - 1; $i += 3) {
            $tb = $a[$i] . $tb;
            $fo = [ $fo, $a[$i+2], $a[$i+1] ];
        }
        $fo = [ $tb, $fo ];
        $fate = $fo;
    }
    # Suppose two fates are different.  They must have a first point of
    # divergence.  This point cannot be a quantifier, because then both fates
    # would end at the quantifier; so it must be a LTM alternation.  But any
    # LTM alternation would generate different sort keys for the sides.
    my @sfates = sort { $b->[0] cmp $a->[0] } @{ $node->[0] };
    @{ $node->[0] } = ();
    for (my $i = 0; $i < @sfates; $i++) {
        next if ($i < @sfates-1 && $sfates[$i][0] eq $sfates[$i+1][0]);
        push @{ $node->[0] }, $sfates[$i][1];
    }

    pop @$node;
    push @$node, _tangle_edges(\@ouredges, $nfa2dfa);
    $node->[1]{DESC} = $id . "{" . join(",", @nfixes) . "}";
    $node->[1]{ID} = $id;

    if (DEBUG & DEBUG::autolexer) {
        print ::LOG "JIT DFA node generation:\n";
        _dfa_dump_node($node);
    }

    $node->[0];
}

sub _scan_regexes { my ($class, $key) = @_;
    no strict 'refs';
    (${ $class . "::REGEXES" } //= do {
        my $stash = \ %{ $class . "::" };
        my %over;
        my %proto;

        for my $m (keys %$stash) {
            next if ref $stash->{$m};  # use constant
            next if !defined *{$stash->{$m}}{CODE};
            my ($meth, $p) = $m =~ /^(.*?)(__S_\d\d\d.*)?__PEEK$/ or next;
            #$self->deb("\tfound override for $meth in $m") if DEBUG & DEBUG::autolexer;
            $over{$meth} = 1;
            push @{$proto{$meth}}, $m if $p;
        }

        for (keys %proto) {
            @{$proto{$_}} = sort @{$proto{$_}};
        }

        $proto{ALL} = [ keys %over ];
        \%proto;
    })->{$key};
}

sub _AUTOLEXgenDFA { my ($self, $realkey, $key, $retree) = @_;
    local $::AUTOLEXED{$realkey} = $fakepos;

    my $lang = ref $self;

    $self->deb("AUTOLEXgen $key in $lang") if DEBUG & DEBUG::autolexer;
    my $ast = $retree->{$key};

    UP: {
        # Whenever possible, we want to share a lexer amongst as many grammars
        # as we can.  So we try to float lexers up to superclasses.

        no strict 'refs';
        my $isa = \@{ $lang . "::ISA" };

        # We don't support multiple inheritance (can we?)
        if (@$isa != 1) {
            $self->deb("\tcannot reuse $key; multiply inherited") if DEBUG & DEBUG::autolexer;
            last;
        }

        my $super = $isa->[0];

        my $dic = $ast->{dic} //= do {
            my $i = 1; # skip _AUTOLEXpeek;
            my $pkg = 'CursorBase';
            $pkg = caller($i++) while $pkg eq 'CursorBase';
            #print STDERR "dic run: $pkg\n";
            $self->deb("\tdeclared in class $pkg") if DEBUG & DEBUG::autolexer;
            $pkg;
        };

        my $ar = ${ $lang . "::ALLROLES" } //= do {
            +{ map { $_->name, 1 } ($lang->meta, $lang->meta->calculate_all_roles) }
        };

        # It doesn't make sense to float a lexer above STD::Cursor, or (for 'has'
        # regexes), the class of definition.
        if ($ar->{$dic}) {
            $self->deb("\tcannot reuse $key; at top") if DEBUG & DEBUG::autolexer;
            last;
        }

        my $supercursor = $self->cursor_fresh($super);
        my $superlexer  = eval {
            local %::AUTOLEXED;
            $supercursor->_AUTOLEXpeek($key, $retree)
        };

        if (!$superlexer) {
            $self->deb("\tcannot reuse $key; failed ($@)") if DEBUG & DEBUG::autolexer;
            last;
        }

        my $ml = _scan_regexes($lang, 'ALL');

        for my $meth (@$ml) {
            if ($superlexer->{USED_METHODS}{$meth}) {
                $self->deb("\tcannot reuse $key; $meth overriden/augmented")
                    if DEBUG & DEBUG::autolexer;
                last UP;
            }
        } 

        $self->deb("\treusing ($key, $realkey, $lang, $super).") if DEBUG & DEBUG::autolexer;
        return $superlexer;
    }

    my $dba = $ast->{dba};

    my $d = DEBUG & DEBUG::autolexer;
    print ::LOG "generating DFA lexer for $key -->\n" if $d;
    my $nfa;

    if ($key =~ /(.*):\*$/) {
        my $proto = $1;
        $dba = $proto;
        my $protopat = $1 . '__S_';
        my $protolen = length($protopat);
        my @alts;
        my $j = 0;
        my @stack = $lang;

        while (@stack) {
            no strict 'refs';
            my $class = pop @stack;
            push @stack, reverse @{ $class . "::ISA" };
            my @methods = @{ _scan_regexes($class, $proto) // [] };
            for my $method (@methods) {
                my $callname = $class . '::' . $method;
                $method = substr($method, 0, length($method)-6);
                my $peeklex = $self->$callname();
                die "$proto has no lexer!?" unless $peeklex->{NFAT};

                push @alts, ["${class}::$method", $peeklex->{NFAT}];
            }
        }

        $nfa = nfa::method($proto, nfa::ltm($proto, @alts));
    } elsif ($ast) {
        $nfa = $ast->nfa($self);
    } else {
        die "BAD KEY";
    }

    die "dba unspecified" unless $dba;

    local @::NFANODES;
    nfa::gnode($nfa, [0], undef);
    my $nfag = \@::NFANODES;
    my %usedmethods = map { $_, 1 } @{ $nfa->{m} };
    $nfa->{m} = [ sort keys %usedmethods ];

    _dump_nfa($key, $nfag) if $d;
    print ::LOG "used methods: ", join(" ", sort keys %usedmethods), "\n" if $d;

    my $dfa   = CORE::bless [], 'CursorBase::dfa';
    push @$dfa, [ undef, { BITS => "\001", ID => 0 } ];

    { DBA => $dba, DFA => $dfa, NFA2DFA => { "\001" => $dfa->[0] },
        NFA => $nfag, NFAT => $nfa, S => $dfa->[0], USED_METHODS => \%usedmethods };
}

sub _AUTOLEXpeek { my $self = shift;
    my $key = shift;
    my $retree = shift;

    # protoregexes are identified by name
    my $realkey = refaddr($retree->{$key}) // $key;

    $self->deb("AUTOLEXpeek $key") if DEBUG & DEBUG::autolexer;
    die "Null key" if $key eq '';
    if ($::AUTOLEXED{$realkey}) {   # no left recursion allowed in lexer!
        die "Left recursion in $key" if $fakepos == $::AUTOLEXED{$realkey};
        $self->deb("Suppressing lexer recursion on $key") if DEBUG & DEBUG::autolexer;
        return { USED_METHODS => {}, NFAT => $nfa::IMP };  # (but if we advanced just assume a :: here)
    }
    $key = 'termish' if $key eq 'EXPR';
    return $::LEXERS{ref $self}->{$realkey} //= do {
        $self->_AUTOLEXgenDFA($realkey, $key, $retree);
    };
}

#############################################################
# Parser service routines
#############################################################

sub O {
    my $self = shift;
    my %args = @_;
    @$self{keys %args} = values %args;
    $self;
}

sub Opairs {
    my $self = shift;
    my $O = $self->{O} or return ();
    my @ret;
    for (my ($k,$v) = each %$O) {
        push @ret, $k, $v;
    }
    @ret;
}

sub gettrait {
    my $self = shift;
    my $traitname = shift;
    my $param = shift;
    my $text;
    if (@$param) {
        $text = $param->[0]->Str;
        $text =~ s/^<(.*)>$/$1/ or
        $text =~ s/^\((.*)\)$/$1/;
    }
    if ($traitname eq 'export') {
        if (defined $text) {
            $text =~ s/://g;
        }
        else {
            $text = 'DEFAULT';
        }
        $self->set_export($text);
        $text;
    }
    elsif (defined $text) {
        $text;
    }
    else {
        1;
    }
}

sub set_export {
    my $self = shift;
    my $text = shift;
    my $textpkg = $text . '::';
    my $name = $::DECLARAND->{name};
    my $xlex = $STD::ALL->{ ($::DECLARAND->{inlex})->[0] };
    $::DECLARAND->{export} = $text;
    my $sid = $::CURLEX->idref;
    my $x = $xlex->{'EXPORT::'} //= Stash::->new( 'PARENT::' => $sid, '!id' => [$sid->[0] . '::EXPORT'] );
    $x->{$textpkg} //= Stash::->new( 'PARENT::' => $x->idref, '!id' => [$sid->[0] . '::EXPORT::' . $text] );
    $x->{$textpkg}->{$name} = $::DECLARAND;
    $x->{$textpkg}->{'&'.$name} = $::DECLARAND
            if $name =~ /^\w/ and $::IN_DECL ne 'constant';
    $self;
}

sub mixin {
    my $self = shift;
    my $WHAT = ref($self)||$self;
    my @mixins = @_;

    my $NEWWHAT = $WHAT . '::';
    my @newmix;
    for my $mixin (@mixins) {
        my $ext = ref($mixin) || $mixin;
        push @newmix, $ext;
        $ext =~ s/(\w)\w*::/$1/g;       # just looking for a "cache" key, really
        $NEWWHAT .= '_X_' . $ext;
    }
    $self->deb("mixin $NEWWHAT from $WHAT @newmix") if DEBUG & DEBUG::mixins;
    no strict 'refs';
    if (not exists &{$NEWWHAT.'::meta'}) {              # never composed this one yet?
        # fake up mixin with MI, being sure to put "roles" in front
        my $eval = "package $NEWWHAT; use Moose ':all' => { -prefix => 'moose_' };  moose_extends('$WHAT'); moose_with(" . join(',', map {"'$_'"} @newmix) . ");our \$CATEGORY = '.';\n";

        $self->deb($eval) if DEBUG & DEBUG::mixins;
        local $SIG{__WARN__} = sub { die $_[0] unless $_[0] =~ /^Deep recursion/ };
        eval $eval;
        warn $@ if $@;
    }
    return $self->cursor_fresh($NEWWHAT);
}

sub tweak {
    my $self = shift;
    my $class = ref $self;
    no strict 'refs';
    for (;;) {
        my $retval = eval {
            $self->deb("Calling $class" . '::multitweak') if DEBUG & DEBUG::mixins;
            &{$class . '::multitweak'}($self,@_);
        }; 
        return $retval if $retval;
        die $@ unless $@ =~ /^NOMATCH|^Undefined subroutine/;
        last unless $class =~ s/(.*)::.*/$1/;
    }
}

# only used for error reporting
sub clean_id { my $self = shift;
    my ($id,$name) = @_;
    my $file = $::FILE->{name};

    $id .= '::';
    $id =~ s/^MY:file<CORE.setting>.*?::/CORE::/;
    $id =~ s/^MY:file<\w+.setting>.*?::/SETTING::/;
    $id =~ s/^MY:file<\Q$file\E>$/UNIT/;
    $id =~ s/:pos\(\d+\)//;
    $id .= "<$name>";
    $id;
}

# remove consistent leading whitespace (mutates text nibbles in place)

sub trim_heredoc { my $doc = shift;
    my ($stopper) = $doc->stopper or
        $doc->panic("Couldn't find delimiter for heredoc\n");
    my $ws = $stopper->{ws}->Str;
    return $stopper if $ws eq '';

    my $wsequiv = $ws;
    $wsequiv =~ s{^(\t+)}[' ' x (length($1) * ($::TABSTOP // 8))]xe;

    # We can't use ^^ after escapes, since the escape may be mid-line
    # and we'd get false positives.  Use a fake newline instead.
    $doc->{nibbles}[0] =~ s/^/\n/;

    for (@{$doc->{nibbles}}) {
        next if ref $_;   # next unless $_ =~ Str;

        # prefer exact match over any ws
        s{(?<=\n)(\Q$ws\E|[ \t]+)}{
            my $white = $1;
            if ($white eq $ws) {
                '';
            }
            else {
                $white =~ s[^ (\t+) ][ ' ' x (length($1) * ($::TABSTOP // 8)) ]xe;
                if ($white =~ s/^\Q$wsequiv\E//) {
                    $white;
                }
                else {
                    '';
                }
            }
        }eg;
    }
    $doc->{nibbles}[0] =~ s/^\n//;  # undo fake newline
    $stopper;
}

sub add_categorical { my $lang = shift;
    my $name = shift;
    state $GEN = "500";
    $name =~ s/:<<(.*)>>$/:«$1»/;
    my $WHAT = ref $lang;

    # :() is a signature modifier, not an operator
    if ($name =~ /^\w+:\(/) {
        # XXX canonicalize sig here eventually
        $lang->add_my_name($name);
        return $lang;
    }

    if ($name =~ s/^(\w+):(?=[«<{[])/$1:sym/) {
        my $cat = $1;
        my ($sym) = $name =~ /:sym(.*)/;
        $sym =~ s/^<\s*(.*\S)\s*>$/<$1>/g;
        $sym =~ s/^\[\s*(.*\S)\s*\]$/$1/g;
        if ( $sym =~ s/\\x\[(.*)\]/\\x{$1}/g) {
            $sym = '«' . eval($sym) . '»';
        }
        elsif ($sym =~ s/\\c\[(.*)\]/\\N{$1}/g ) {
            $sym = '«' . eval("use charnames ':full'; $sym") . '»';
        }

        # unfortunately p5 doesn't understand q«...»
        if ($sym =~ s/^«\s*(.*\S)\s*»$/$1/) {
            my $ok = "'";
            for my $try (qw( ' / ! : ; | + - = )) {
                $ok = $try, last if index($sym,$try) < 0;
            }
            $sym = $ok . $sym . $ok;
        }
        {
            my $canon = substr($sym,1,length($sym)-2);
            $canon =~ s/([<>])/\\$1/g;
            my $canonname = $cat . ':<' . $canon . '>';
            $lang->add_my_name($canonname);
        }
        if ($sym =~ / /) {
            $sym = '[qw' . $sym . ']';
        }
        else {
            $sym = 'q' . $sym;
        }

        my $rule = "token $name { <sym> }";

        # produce p5 method name
        my $mangle = $name;
        $mangle =~ s/^(\w*):(sym)?//;
        my $category = $1;
        my @list;
        if ($mangle =~ s/^<(.*)>$/$1/ or
            $mangle =~ s/^«(.*)»$/$1/) {
            $mangle =~ s/\\(.)/$1/g;
            @list = $mangle =~ /(\S+)/g;
        }
        elsif ($mangle =~ s/^\[(.*)\]$/$1/ or
            $mangle =~ s/^\{(.*)\}$/$1/) {
            $mangle =~ s/\\x\[(.*)\]/\\x{$1}/g;
            @list = eval $mangle;
        }
        elsif ($mangle =~ m/^\(\"(.*)\"\)$/) {
            @list = eval $sym;
        }
        else {
            @list = $mangle;
        }
        $mangle = ::mangle(@list);
        $mangle = $category . '__S_' . sprintf("%03d",$GEN++) . $mangle;

        # XXX assuming no equiv specified, but to do that right,
        # this should be delayed till the block start is seen
        my $coercion = '';
        if ($name =~ /^infix:/) {
            $coercion = 'additive';
        }
        elsif ($name =~ /^prefix:/) {
            if ($sym =~ /^.\W/) {
                $coercion = 'symbolic_unary';
            }
            else {
                $coercion = 'named_unary';
            }
        }
        elsif ($name =~ /^postfix:/) {
            $coercion = 'methodcall';
        }
        elsif ($name =~ /^circumfix:/) {
            $coercion = 'term';
        }
        elsif ($name =~ /^postcircumfix:/) {
            $coercion = 'methodcall';
        }
        elsif ($name =~ /^term:/) {
            $coercion = 'term';
        }

        state $genpkg = 'ANON000';
        $genpkg++;
        my $e;
        if (@list == 1) {
            $e = <<"END";
package $genpkg;
use Moose ':all' => { -prefix => 'moose_' };
moose_extends('$WHAT');

# $rule

my \$retree = {
    '$mangle' => bless({
        'dba' => '$category expression',
        'kind' => 'token',
        'min' => 12345,
        're' => bless({
            'a' => 0,
            'i' => 0,
            'min' => 12345,
            'name' => 'sym',
            'rest' => '',
            'sym' => $sym,
        }, 'RE_method'),
    }, 'RE_ast'),
};

our \$CATEGORY = '$category';

sub ${mangle}__PEEK { \$_[0]->_AUTOLEXpeek('$mangle',\$retree) }
sub $mangle {
    my \$self = shift;
    local \$CTX = \$self->callm() if \$::DEBUG & DEBUG::trace_call;
    my %args = \@_;
    my \$sym = \$args{sym} // $sym;

    my \$xact = ['RULE $mangle', 0, \$::XACT];
    local \$::XACT = \$xact;

    my \$S = \$self->{_pos};
    my \$C = \$self->cursor_xact("RULE $mangle \$S");
#    my \$xact = \$C->xact;

    \$C->{'sym'} = \$sym;

    \$self->_MATCHIFY(\$S, '$mangle',
        do {
            if (my (\$C) = (\$C->_SYM(\$sym, 0))) {
                \$C->_SUBSUMEr(['O'], sub {
                    my \$C = shift;
                    \$C->O(%STD::$coercion)
                });
            }
            else {
                ();
            }
        }
    );
}
1;
END
        }
        else {
            for (@list) {
                if (/'/) {
                    s/(.*)/"$1"/;
                }
                else {
                    s/(.*)/'$1'/;
                }
            }
            my $starter = $list[0];
            my $stopper = $list[1];

            $e = <<"END";
package $genpkg;
use Moose ':all' => { -prefix => 'moose_' };
moose_extends('$WHAT');

# $rule

my \$retree = {
 '$mangle' => bless({
  'dba' => '$category expression',
  'kind' => 'token',
  'min' => 12347,
  'pkg' => undef,
  're' =>  bless({
    'decl' => [],
    'a' => 0,
    'dba' => '$category expression',
    'i' => 0,
    'min' => 12347,
    'r' => 1,
    's' => 0,
    'zyg' => [
        bless({
          'a' => 0,
          'dba' => '$category expression',
          'i' => 0,
          'min' => 1,
          'r' => 1,
          's' => 0,
          'text' => $starter,
        }, 'RE_string'),
        bless({
          'a' => 0,
          'dba' => '$category expression',
          'i' => 0,
          'min' => 12345,
          'name' => 'semilist',
          'r' => 1,
          'rest' => '',
          's' => 0,
        }, 'RE_method'),
        bless({
          'decl' => [],
          'min' => 1,
          're' =>  bless({
            'a' => 0,
            'dba' => '$category expression',
            'i' => 0,
            'min' => 1,
            'r' => 1,
            's' => 0,
            'zyg' => [
                bless({
                  'a' => 0,
                  'dba' => '$category expression',
                  'i' => 0,
                  'min' => 1,
                  'r' => 1,
                  's' => 0,
                  'text' => $stopper,
                }, 'RE_string'),
                bless({
                  'min' => 0,
                  'name' => 'FAILGOAL',
                  'nobind' => 1,
                }, 'RE_method'),
            ],
          }, 'RE_first'),
        }, 'RE_bracket'),
        bless({
          'min' => 0,
          'name' => 'O',
          'rest' => '(|%term)',
        }, 'RE_method'),
    ],
  }, 'RE_sequence'),
 }, 'RE_ast'),
};

our \$CATEGORY = '$category';

sub ${mangle}__PEEK { \$_[0]->_AUTOLEXpeek('$mangle',\$retree) }
sub $mangle {
    no warnings 'recursion';
    my \$self = shift;
    local \$::CTX = \$self->callm() if \$::DEBUG & DEBUG::trace_call;
    my %args = \@_;
    local \$::sym = \$args{sym} // $sym;
    return () if \$::GOAL eq $starter;

    my \$C = \$self->cursor_xact("RULE $mangle");
    my \$xact = \$C->xact;
    my \$S = \$C->{'_pos'};
    \$C->{'sym'} = ref \$sym ? join(' ', \@\$sym) : \$sym;

    \$self->_MATCHIFYr(\$S, "$mangle", 
    do {
      if (my (\$C) = (\$C->_EXACT($starter))) {
        do {
          if (my (\$C) = (((local \$::GOAL = $stopper , my \$goalpos = \$C), \$C->unbalanced($stopper))[-1])) {
            do {
              if (my (\$C) = (\$C->_SUBSUMEr(['semilist'], sub {
                my \$C = shift;
                \$C->semilist
              }))) {
                do {
                  if (my (\$C) = (\$C->_BRACKETr(sub {
                  my \$C=shift;
                  do {
                    my \$C = \$C->cursor_xact('ALT ||');
                    my \$xact = \$C->xact;
                    my \@gather;
                    do {
                      push \@gather, \$C->_EXACT($stopper)
                    }
                    or \$xact->[-2] or
                    do {
                      push \@gather, \$C->FAILGOAL($stopper , '$category expression',\$goalpos)};
                    \@gather;
                  }
                }))) {
                    \$C->_SUBSUMEr(['O'], sub {
                        my \$C = shift;
                        \$C->O(%STD::$coercion)
                      });
                  }
                  else {
                    ();
                  }
                };
              }
              else {
                ();
              }
            };
          }
          else {
            ();
          }
        };
      }
      else {
        ();
      }
    }
    );
}

1;
END
        }
        $lang->deb("derive $genpkg from $WHAT adding $mangle") if DEBUG & DEBUG::mixins;
        eval $e or die "Can't create $name: $@\n";
        $::LANG{'MAIN'} = $lang->cursor_fresh($genpkg);
    }
    $lang;
}

sub add_enum { my $self = shift;
    my $type = shift;
    my $expr = shift;
    return unless $type;
    return unless $expr;
    my $typename = $type->Str;
    local $::IN_DECL = 'constant';
    # XXX complete kludge, really need to eval EXPR
    $expr =~ s/:(\w+)<\S+>/$1/g;  # handle :name<string>
    for ($expr =~ m/([a-zA-Z_]\w*)/g) {
        $self->add_name($typename . "::$_");
        $self->add_name($_);
    }
    $self;
}

sub do_use { my $self = shift;
    my $module = shift;
    my $args = shift;
    my @imports;

    $self->do_need($module);
    $self->do_import($module,$args);
    $self;
}

sub do_need { my $self = shift;
    my $m = shift;
    my $module = $m->Str;
    my $topsym = $self->sys_load_modinfo($module);
    $self->add_my_name($module);
    $::DECLARAND->{really} = $topsym;
    $self;
}

sub do_import { my $self = shift;
    my $m = shift;
    my $args = shift;
    my @imports;
    my $module = $m->Str;
    if ($module =~ /(class|module|role|package)\s+(\S+)/) {
        $module = $2;
    }

    my $pkg = $self->find_stash($module);
    if ($pkg->{really}) {
        $pkg = $pkg->{really}->{UNIT};
    }
    else {
        $pkg = $self->find_stash($module . '::');
    }
    if ($args) {
        my $text = $args->Str;
        return $self unless $text;
        while ($text =~ s/^\s*:?(OUR|MY|STATE|HAS|AUGMENT|SUPERSEDE)?<(.*?)>,?//) {
            my $scope = lc($1 // 'my');
            my $imports = $2;
            local $::SCOPE = $scope;
            @imports = split ' ', $imports;
            for (@imports) {
                if ($pkg) {
                    if ($_ =~ s/^://) {
                        my @tagimports;
                        eval { @tagimports = keys %{ $pkg->{'EXPORT::'}->{$_} }; };
                        $self->do_import_aliases($pkg, @tagimports);
                    }
                    elsif ($pkg->{$_}{export}) {
                        $self->add_my_name($_, $pkg->{$_});
                    }
                    elsif ($pkg->{'&'.$_}{export}) {
                        $_ = '&' . $_;
                        $self->add_my_name($_, $pkg->{$_});
                    }
                    elsif ($pkg->{$_}) {
                        $self->worry("Can't import $_ because it's not exported by $module");
                        next;
                    }
                }
                else {
                    $self->add_my_name($_);
                }
            }
        }
    }
    else {
        return $self unless $pkg;
        eval { @imports = keys %{ $pkg->{'EXPORT::'}->{'DEFAULT::'} }; };
        local $::SCOPE = 'my';
        $self->do_import_aliases($pkg, @imports);
    }

    $self;
}

sub do_import_aliases {
    my $self = shift;
    my $pkg = shift;
#    say "attempting to import @_";
    for (@_) {
        next if /^!/;
        next if /^PARENT::/;
        next if /^OUTER::/;
        $self->add_my_name($_, $pkg->{$_});
    }
    $self;
}

sub canonicalize_name { my $self = shift;
    my $name = shift;
    $name =~ s/^([\$\@\%\&])(\^|:(?!:))/$1/;
    $name =~ s/\b:[UD_]$//;
    return $name unless $name =~ /::/;
    $self->panic("Can't canonicalize a run-time name at compile time: $name") if $name =~ /::\(/;
    $name =~ s/^([\$\@%&][!*=?:^.]?)(.*::)(.*)$/$2<$1$3>/;
    my $vname;
    if ($name =~ s/::<(.*)>$//) {
        $vname = $1;
    }
    my @components = split(/(?<=::)/, $name, -1);
    shift(@components) while @components and $components[0] eq '';
    if (defined $vname) {
        $components[-1] .= '::' if @components and $components[-1] !~ /::$/;
        push(@components, $vname) if defined $vname;
    }
    @components;
}

sub lookup_dynvar { my $self = shift;
    my $name = shift;
    no strict 'refs';
    if ($name =~ s/^\$\?/::/) {
        return $$name if defined $$name;
    }
    elsif ($name =~ s/^\@\?/::/) {
        return \@$name if defined *$name{ARRAY};
    }
    elsif ($name =~ s/^\%\?/::/) {
        return \%$name if defined *$name{HASH};
    }
    return
}

sub mark_sinks { my $self = shift;
    my $statements = shift;
    return $self unless @$statements;
    my @s = @$statements;
    my $final = pop(@s);
    for my $s (@s) {
        if ($s->is_pure) {
            $self->worry("Useless use of " . $s->Str . " in sink context");
        }
        $s->{_pure} = 1;   # nothing is pure :)
        $s->{_sink} = 1;
    }
    $self;
}

sub is_pure { my $self = shift;
    return 1 if $self->{_pure};
    # visit kids here?
    return 0;
}

sub check_old_cclass { my $self = shift;
    my $innards = shift;

    my $prev = substr($::ORIG,$self->{_pos}-length($innards)-4,2);
    return $self if $prev =~ /=\s*$/;       # don't complain on $var = [\S] capture

    my $cclass = '';
    my $single = '';
    my $singleok = 1;
    my $double = '';
    my $doubleok = 1;

    my $last = '';
    my %seen;

    my $i = $innards;
    my $neg = '';
    $neg = '-' if $i =~ s/^\^//;
    my $digits = 0;
    $i =~ s/0-9/\\d/;
    while ($i ne '') {
        if ($i =~ s/^-(.)/$1/) {
            $singleok = $doubleok = 0;
            $cclass .= $last ? '..' : '\\-';
            $last = '';
        }
        elsif ($i =~ /^\|./ and $cclass ne '') {
            return $self;       # probable alternation
        }
        elsif ($i =~ s/^\|//) {
            $last = '';
            $singleok = $doubleok = 0;
            $cclass .= '|';
        }
        elsif ($i =~ /^[*+?]/ and $cclass ne '') {
            return $self;       # probable quantifier
        }
        elsif ($i =~ s/^\\?'//) {
            $last = "'";
            $single .= '\\' . $last;
            $double .= $last;
            $cclass .= $last;
        }
        elsif ($i =~ s/^\\?"//) {
            $last = '"';
            $single .= $last;
            $double .= '\\' . $last;
            $cclass .= $last;
        }
        elsif ($i =~ s/^(\\[btnrf0])//) {
            $last = eval '"' . $1 . '"';
            $single .= $last;
            $double .= $1;
            $cclass .= $1;
        }
        elsif ($i =~ s/(\\x\w\w)//) {
            $last = eval '"' . $1 . '"';
            $single .= $last;
            $double .= $1;
            $cclass .= $1;
        }
        elsif ($i =~ s/(\\0[0-7]{1,3})//) {
            $last = eval '"' . $1 . '"';
            $single .= $last;
            $double .= "\\o" . substr($1,1);
            $cclass .= "\\o" . substr($1,1);
        }
        elsif ($i =~ s/^(\\[sSwWdD])//) {
            $singleok = $doubleok = 0;
            $last = '';
            $cclass .= $1;
        }
        elsif ($i =~ s/^(\\?\t)//) {
            $last = "\t";
            $single .= $last;
            $double .= '\\t';
            $cclass .= '\\t';
        }
        elsif ($i =~ s/^(\\?\x20)//) {
            $last = ' ';
            $single .= $last;
            $double .= $last;
            $cclass .= '\\x20';
        }
        elsif ($i =~ s/^\.//) {
            $last = '.';
            $singleok = $doubleok = 0;
            $cclass .= '.';
        }
        elsif ($i =~ s/^\\(.)//) {
            $last = $1;
            $single .= $last;
            $double .= '\\' . $last;
            $cclass .= '\\' . $last;
        }
        elsif ($i =~ s/^(.)//s) {
            $last = $1;
            $cclass .= $last;
            $single .= $last;
            $double .= $last;
        }
        else {
            die "can't happen";
        }

        if ($last ne '' and $seen{$last}++) {
            return $self;       # dup likely indicates not a character class
        }
    }

    my $common = "[$innards] appears to be an old-school character class;";

    # XXX not Unicodey yet
    if ($neg) {
        return $self->worry("$common non-digits should be matched with \\D instead") if $cclass eq '\\d';
        return $self->worry("$common non-newlines should be matched with \\N instead") if $cclass eq '\\n';
        if ($singleok) {
            return $self->worry("$common non-(horizontal whitespace) should be matched with \\H instead") if $single =~ /\A[ \t\b\r]*\z/;
            return $self->worry("$common non-(vertical whitespace) should be matched with \\V instead") if $single =~ /\A[\n\f]*\z/;
            return $self->worry("$common non-whitespace should be matched with \\S instead") if $single =~ /\A[ \t\b\r\n\f]*\z/;
            return $self->worry("$common please use <-[$cclass]> if you mean a character class");
        }
        elsif ($doubleok) {
            return $self->worry("$common please use <-[$cclass]> if you mean a character class");
        }
    }
    else {
        return $self->worry("$common digits should be matched with \\d instead") if $cclass eq '\\d';
        if ($singleok) {
            return $self->worry("$common horizontal whitespace should be matched with \\h instead") if $single =~ /\A[ \t\b\r]*\z/;
            return $self->worry("$common vertical whitespace should be matched with \\v instead") if $single =~ /\A[\n\f]*\z/;
            return $self->worry("$common whitespace should be matched with \\s instead") if $single =~ /\A[ \t\b\r\n\f]*\z/;
        }
        if ($singleok and $single eq $double) {
            return $self->worry("$common please use <[$cclass]> if you\n    mean a character class, or quote it like '$single' to match\n    string as a unit");
        }
        elsif ($doubleok) {
            return $self->worry("$common please use <[$cclass]> if you\n    mean a character class, or quote it like \"$double\" to match\n    string as a unit");
        }
    }
    if ($::FATALS) {
        return $self->worry("$common please use <${neg}[$cclass]> if you mean a character class");
    }
    else {
        return $self->worry("$common please use <${neg}[$cclass]> if you\n    mean a character class, or put whitespace inside like [ $innards ] to disable\n    this warning");
    }
    $self;
}

## vim: expandtab sw=4
