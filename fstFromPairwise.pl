#!/usr/bin/env perl
use strict;
use warnings;
use Data::Dumper;
use Getopt::Long;
use Algorithm::Combinatorics qw(combinations);
use List::Util qw/sum/;
use File::Basename;
use Time::HiRes qw/time/;
use Math::Random::MT; # for precision 64 bit numbers

use threads;
use Thread::Queue;

$0=basename $0;
sub logmsg{$|++;print STDERR "TID".threads->tid." $0: @_\n";$|--;}

exit main();
sub main{
  my $settings={};
  GetOptions($settings,qw(help minimum=i maximum=i numcpus=i sample=s buffer=i)) or die usage();
  die usage() if($$settings{help});
  $$settings{numcpus}||=1;
  $$settings{sample}||=1; # sampling frequency goes from 0 to 1
  $$settings{minimum}||=2;
  $$settings{minimum}=2 if($$settings{minimum} < 2);
  $$settings{buffer}||=99999;
  $$settings{buffer}=1 if($$settings{buffer} < 1);

  logmsg "Sampling frequency is $$settings{sample}; Buffer is $$settings{buffer}.";

  die "ERROR: sample must be between 0 and 1. It was set as $$settings{sample}\n".usage() if($$settings{sample} < 0 || $$settings{sample} > 1);

  logmsg "Finding distances";
  my %distance=distances($settings);
  my @id=keys(%distance);
  my $numTaxa=@id;
  my $maxTaxa=$$settings{maximum} || int($numTaxa/2); # only need to sample up to half because you really probably want half vs half when considering Fst
  logmsg "Warning: you have more than 10 as your max. This can produce many results and take a long time." if($maxTaxa > 10);
  #logmsg "Up to $maxTaxa taxa will be counted in groups: there will be ".numCombinations($maxTaxa,$settings)." combinations";

  logmsg "Calculating fixation indices";
  printFst(\@id,\%distance,$maxTaxa,$settings);
  return 0;
}

sub printFst{
  my($id,$distance,$maxTaxa,$settings)=@_;

  # set up the threads
  my $Q=Thread::Queue->new;
  my $printQ=Thread::Queue->new;
  my @thr;
  $thr[$_]=threads->new(\&fstWorker,$Q,$printQ,$distance,$id,$settings) for(0..$$settings{numcpus}-1);
  my $printer=threads->new(\&printer,$printQ,$$settings{numcpus},$settings);

  my @fst;
  my $groupCount=0;
  my $minTaxa=$$settings{minimum};
  my $buffer=$$settings{buffer};
  for(my $numInGroup=$minTaxa;$numInGroup<=$maxTaxa;$numInGroup++){
    my @group1;
    my $iter=combinations($id,$numInGroup);
    while(my $group1=$iter->next){
      $groupCount++;
      push(@group1,$group1);
      if(@group1>$buffer){
        logmsg "Enqueuing $buffer combinations of size $numInGroup";
        $Q->enqueue(@group1);
        @group1=();
        sleep 1 if($Q->pending > ($buffer * $buffer));
      }
    }
    $Q->enqueue(@group1);
  }
  logmsg "Done enqueuing $groupCount combinations of taxa";

  # close off the threads
  $Q->enqueue(undef) for(@thr);
  $_->join for(@thr);
  $printer->join;

}

sub distances{
  my($settings)=@_;
  my %distance;
  my $i=0;
  while(<STDIN>){
    chomp;
    my($id1,$id2,$dist)=split /\t/;
    $distance{$id1}{$id2}=$dist;
    $distance{$id2}{$id1}=$dist;

    if(++$i % 10000 == 0){
      logmsg "Finished with $i distances";
    }
  }
  logmsg "Finished loading all $i distances from the pairwise comparison file";
  return %distance;
}

sub fstWorker{
  my($Q,$printQ,$distance,$groupId,$settings)=@_;

  # new copy of some variables so that it doesn't trip over other threads
  my %distance=%$distance; 
  my @groupId=@$groupId;

  my $numGen=Math::Random::MT->new; # for 64-bit numbers
  my($skipCount,$processCount);
  my @buffer;
  while(defined(my $group1=$Q->dequeue)){
    #if($numGen->rand >= $$settings{sample}){ # for random sampling
    #  $skipCount++;
    #  next;
    #} else {
    #  logmsg "!";
    #  $processCount++;
    #}
    my $group2=theExcludedGroup($group1,\@groupId,$settings);
    my $fst=fst($group1,$group2,\%distance,$settings);

    push(@buffer,join("\t",$fst,join(",",@$group1))."\n");
    if(@buffer > 9){ # keep a small buffer
      $printQ->enqueue(@buffer);
      @buffer=();
    }
  }
  $printQ->enqueue(@buffer);

  $printQ->enqueue(undef); # all fstWorkers need to signal before the printer stops
}

sub printer{
  my($Q,$numcpus,$settings)=@_;
  my $numPrinted=0;
  my $numSignals=0; # number of threads that kill the printer
  while(1){
    my $thing=$Q->dequeue;
    if(!defined($thing)){
      $numSignals++;
      #logmsg "Received $numSignals so far (need to have >= $numcpus)";
      last if($numSignals >= $numcpus);
      next;
    }
    print $thing;
    $numPrinted++;
  }
}

sub theExcludedGroup{
  my($inGroup,$totalGroup,$settings)=@_;
  my @outGroup;
  my @inGroup=@$inGroup; # instead of constantly dereferencing it
  for my $id (@$totalGroup){
    push(@outGroup,$id) if(!grep(/^\Q$id\E$/,@$inGroup));
  }
  return \@outGroup;
}

sub fst{
  my($group1,$group2,$distance,$settings)=@_;
  my $within1=averageGroupDistance($group1,$group1,$distance,1,$settings);
  my $within2=averageGroupDistance($group2,$group2,$distance,1,$settings);
  # for some reason, this takes a very long time to run when multithreaded
  my $between=averageGroupDistance($group1,$group2,$distance,0,$settings);

  my $numGroup1=@$group1;
  my $numGroup2=@$group2;
  my $total=$numGroup1+$numGroup2;
  my $within=($within1*$numGroup2/$total + $within2*$numGroup1/$total)/2;
  my $fst=($between-$within)/$between;
  return $fst;
}

# specify the $is_same parameter to note that the two groups are really the same group.
sub averageGroupDistance{
  my($id1,$id2,$distance,$is_same,$settings)=@_;
  my @distance;
  my %seen;
  for(my $i=0;$i<@$id1;$i++){
    my $j=0;
    $j=$i+1 if($is_same);
    for(my $j=$j;$j<@$id2;$j++){
      push(@distance,$$distance{$$id1[$i]}{$$id2[$j]});
    }
  }
  return 0 if(!@distance);
  return sum(@distance)/@distance;
}

sub numCombinations{
  my($totalNum,$settings)=@_;
  return 0 if($totalNum<2);
  my $sum=0;
  # iterate from 2 to the total number that can be chosen from
  for my $subNum(2..$totalNum){
    # iterate from 2 to the specific subpopulation
    for my $choose(2..$subNum){
      $sum+=factorial($subNum)/(factorial($choose) * factorial($subNum - $choose));
    }
  }
  return $sum;
}

sub factorial{
  my $num=shift;
  return 1 if($num<=1);
  my $prod=1;
  for(my $i=$num;$i>1;$i--){
    $prod=$i*$prod;
  }
  return $prod;
}

sub usage{
  "Finds the Fst for all combinations of groups.
  Usage: $0 [options] < pairwise.tsv > Fst.tsv
  -max maximum number of taxa in a group for Fst. Default: half the total number of taxa
  -min opposite of max (default: 2)
  --numcpus 1 The number of cpus you want to throw at it
  --sample 1 The sampling frequency where 1 is to get 100% of all applicable Fst measurements.
  --buffer 99999 The number of combinations to hold before performing calculations. With small sampling frequency, you can reduce this number to see more results in real time. Otherwise this will help speed up the script at the cost of some RAM.
  pairwise.tsv is a three-column file with: genome1 genome2 distance
  Output (Fst.tsv) is a two-column file with Fst and comma-separated taxa
  "
}
