#!/usr/bin/perl -w
####################################################################################################
#
# Helper script for Qt 5
#
# Copyright (C) 2010 Nokia Corporation and/or its subsidiary(-ies).
# Contact: Nokia Corporation (qt-info@nokia.com)
#
####################################################################################################

############################################################################################
#
# Convenience script working with a Qt 5 repository.
#
# Feel free to add useful options!
#
############################################################################################

use strict;

use Getopt::Long;
use File::Basename;
use Cwd;
use File::Spec;
use POSIX;
use IO::File;

my $CLEAN=0;
my $DOC=0;
my $PULL=0;
my $BUILD=0;
my $RESET=0;
my $DIFF=0;

my $USAGE=<<EOF;
Usage: qt5_tool.pl [OPTIONS]

Utility script for working with Qt 5 modules.

Feel free to extend!

Options:
  -d  Diff (over all modules, relative to root)
  -r  Reset hard
  -c  Clean
  -p  Pull
  -b  Build
  -o  [D]ocumentation

Example use cases:
  qt5_tool.pl -c -p -b     Clean, pull and build for nightly builds
  qt5_tool.pl -d           Generate modules diff relative to root directory
  qt5_tool.pl -r           Reset --hard of repo.
EOF

my %preferredBranches = ( 'qtwebkit' , 'qt-modularization-base' );

# --------------- Detect OS

my ($OS_LINUX, $OS_WINDOWS, $OS_MAC)  = (0, 1, 2);
my $os = $OS_LINUX;
if (index($^O, 'MSWin') >= 0) {
    $os = $OS_WINDOWS;
} elsif (index($^O, 'darwin') >= 0) {
   $os = $OS_MAC;
}

my $make = $os == $OS_WINDOWS ? 'jom' : 'make';
my @makeArgs = $os == $OS_WINDOWS ? () : ('-s');
my $git = 'git'; # TODO: Mac, Windows special cases?

my $rootDir = '';

# --- Fix a diff line from a submodule such that it can be applied to
#     the root Qt 5 directory, that is:
#     '--- a/foo...' -> '--- a/<module>/foo...'

sub fixDiff
{
   my ($line, $module) = @_;
   if (index($line, '--- a/') == 0 || index($line, '+++ b/') == 0) {
       return substr($line, 0, 6) . $module . '/' . substr($line, 6);
   }
   if (index($line, 'diff --git ') == 0) {
       $line =~ s| a/| a/$module/|;
       $line =~ s| b/| b/$module/|;
   }
   return $line;
}

# ---- Generate a diff from all submodules such that it can be applied to
#      the root Qt 5 directory.

sub diff
{
    my $totalDiff = '';
    my ($rootDir,$modArrayRef) = @_;
    foreach my $MOD (@$modArrayRef) {
     chdir($MOD) or die ('Failed to chdir from' . $rootDir . ' to "' . $MOD . '":' . $!);
     my $diffOutput = `$git diff`;
     foreach my $line (split(/\n/, $diffOutput)) {
         chomp($line);
         $totalDiff .= fixDiff($line, $MOD);
         $totalDiff .= "\n";
     }
     chdir($rootDir);
  }
  return $totalDiff;
}

# ---- Read a value from a git config line.

sub readConfig
{
    my ($module, $key) = @_;

    my $configLine = '';
    my $configFileName = File::Spec->catfile($rootDir, $module, '.git', 'config');
    my $configFile = new IO::File('<' . $configFileName) or return $configLine;
    while (my $line = <$configFile>) {
        chomp($line);
        if ($line =~ /^\s*$key\s*=\s*(.*)$/) {
           $configLine .= $1;
           last;
        }
    }
    $configFile->close();
    return $configLine;
}

# ---- Check for absolute path names.

sub isAbsolute
{
    my ($file) = @_;
    return index($file, ':') == 1 if ($os == $OS_WINDOWS);
    return index($file, '/') == 0;
}

# --------------- MAIN: Parse arguments

if (!GetOptions("clean" => \$CLEAN, "ocumentation" => \$DOC,
     "pull" => \$PULL, "reset" => \$RESET, "diff" => \$DIFF,
     "build" => \$BUILD)
    || ($CLEAN + $DOC + $PULL + $BUILD + $RESET + $DIFF == 0)) {
    print $USAGE;
    exit (1);
}

# --- Change to root: Assume we live in qtrepotools below root.
#     Note: Cwd::realpath is broken in the Symbian-perl-version.
my $prog = $0;
$prog = Cwd::realpath($0) unless isAbsolute($prog);
$rootDir = dirname(dirname($prog));
chdir($rootDir) or die ('Failed to chdir to' . $rootDir . '":' . $!);

# ---- Determine modules by trying to find <module>/.git/config.

my @MODULES = ();
opendir (DIR, $rootDir) or die ('Cannot read ' . $rootDir . $!);
while (my $e = readdir(DIR)) {
   if ($e ne '.' && $e ne '..') {
       push(@MODULES, $e) if (-d $e && -f (File::Spec->catfile($e, '.git','config')));
   }
}
closedir(DIR);
die ('Failed to detect modules in ' . $rootDir . ".\nNeeds to be called from the root directory.") if @MODULES == 0;

print diff($rootDir, \@MODULES) if $DIFF;

# --------------- Reset: Save to a patch in HOME dir indicating date in
#                 file name should there be a diff.
if ( $RESET !=  0 ) {
  print 'Resetting Qt 5 in ',$rootDir,"\n";
  my $changes = diff($rootDir, \@MODULES);
  if ($changes ne '') {
     my $home = $os == $OS_WINDOWS ? ($ENV{'HOMEDRIVE'} . $ENV{'HOMEPATH'}) : $ENV{'HOME'};
     my $patch = File::Spec->catfile($home, POSIX::strftime('qt5_d%Y%m%d%H%M.patch',localtime));
     my $patchFile = new IO::File('>' . $patch) or die ('Unable to open for writing ' .  $patch . ' :' . $!);
     print $patchFile $changes;
     $patchFile->close();
     print 'Saved ', $patch, "\n";
  }
  system($git, ('reset','--hard'));
  system($git, ('submodule','foreach',$git,'reset','--hard'));
}

# --------------- Clean if desired

if ( $CLEAN !=  0 ) {
  print 'Cleaning Qt 5 in ',$rootDir,"\n";
  system($git, ('clean','-dxf'));
  system($git, ('submodule','foreach',$git,'clean','-dxf'));
}

# ---- Pull: Switch to branch unless there is one (check preferred
#      branch hash, default to branch n+1, which is mostly master).

if ( $PULL !=  0 ) {
  print 'Pulling Qt 5 in ',$rootDir,"\n";
  my $prc = system($git, ('pull'));
  die 'Pull failed'  if ($prc);
  foreach my $MOD (@MODULES) {
     print 'Examining: ', $MOD, ' url: ',readConfig($MOD, 'url'), ' ';
     chdir($MOD) or die ('Failed to chdir from' . $rootDir . ' to "' . $MOD . '":' . $!);
     my @branches = split("\n", `$git branch`);
     my @currentBranches = grep(/^\* /, @branches);
     die ('Unable to determine branch of ' . $MOD) if @currentBranches != 1;
     my $currentBranch = substr($currentBranches[0], 2);
     if ($currentBranch eq '(no branch)') {
        # Switch to suitable branch when none is set initially.
        my $desiredBranch = $preferredBranches{$MOD};
        $desiredBranch = substr($branches[1],2) unless defined $desiredBranch;
        die ('Unable to determine suitable branch for ' . $MOD) if not defined $desiredBranch;
        print 'Switching ',$MOD, ' from ', $currentBranch,' to ',$desiredBranch,"\n";
        my $rc = system($git, ('checkout', $desiredBranch));
        die 'Checkout of ' . $desiredBranch . ' failed'  if ($rc);
     } else {
        print ' branch: ',$currentBranch,"\n";
     }
     print 'Pulling ', $MOD, "\n";
     $prc = system($git, ('pull'));
     die 'Pull ' . $MOD . ' failed'  if ($prc);
     chdir($rootDir);
  }
}

# ---- Configure and build

if ( $BUILD !=  0 ) {
  print 'Building Qt 5 in ',$rootDir,"\n";
  my $brc = system(File::Spec->catfile($rootDir, 'configure'),('-nokia-developer'));
  die 'Configure failed'  if ($brc);
  $brc = system($make, @makeArgs);
  die ($make . ' failed')  if ($brc);
}

# ---- Untested: Build documentation.

if ($DOC !=  0 ) {
   print 'Documenting Qt 5 in ',$rootDir,"\n";
   my $drc = system($make, (@makeArgs,'docs'));
   die ($make . ' docs failed')  if ($drc);
}
