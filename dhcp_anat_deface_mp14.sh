#!/bin/bash

# defacing to produce output very close to /vol/dhcp-derived-data/defaced_1feb21 at ICL
# which appears it was used for release

# usage: dhcp_anat_deface_mp14.sh --subject=CC00839XX23 --session=23710 --ga=44.71

set -e
set -u # or set -o nounset

host=$(hostname)
if [ $host != "perinatal117-pc" ]; then
  echo "warning: set up to run by mp14 on perinatal117-pc, modify paths and set up tools!";
fi


subject=CC00810XX10
session=29010
ga=40.71

# subject=CC00839XX23
# session=23710
# ga=44.71

# subject=CC01057XX10
# session=83830
# ga=43.57

dockertag=rel3newmirtk # new-mirtk

for i in "$@"
do
case $i in
    --subject=*)
    subject="${i#*=}"

    ;;
    --session=*)
    session="${i#*=}"
    ;;
    --ga=*)
    ga="${i#*=}"
    ;;
    --dockertag=*)
    dockertag="${i#*=}"
    ;;
    *)
    echo unknown option: ${i}
    exit 1
    ;;
esac
done

echo subject = ${subject}
echo session = ${session}
echo ga = ${ga}
echo dockertag = ${dockertag}

# input raw data dir:
scandir=/pnraw01/dhcp-reconstructions/ReconstructionsRelease07/dHCPNeonatal/sub-$subject/ses-$session

# output data dir:
# rootdir=/pnraw01/dhcp-reconstructions/dhcp_neo_struct_pipeline
rootdir=~/isi01/dhcp-pipeline-data/kcl/structural_neo
# rootdir can be anywhere but needs write access on machine with docker and gpubeastie04
# sshfs mounted does not work out of the box:
# https://serverfault.com/questions/947182/mount-a-sshfs-volume-into-a-docker-instance

tmpdir=$rootdir/tmp
struct=$rootdir/processed_$dockertag

scan=$subject-$session
workdir=$struct/workdir/$scan
dofdir=$struct/workdir/$scan/dofs
anat=$struct/derivatives/sub-$subject/ses-$session/anat

out=$struct/defaced/sub-$subject/ses-$session

MIRTK="ssh gpubeastie04 /home/mp14/bin/mirtk"
MRTRIXBIN=${rootdir}/bin/mrtrix3_standalone/
PATH=$MRTRIXBIN:$PATH

# ____________________ input data prep ____________________

mkdir -p $struct/
mkdir -p $rootdir/raw/sub-$subject/ses-$session/anat
mkdir -p $tmpdir


T2in=$rootdir/raw/sub-$subject/ses-$session/anat/sub-${subject}_ses-${session}_T2w.nii.gz
T1in=$rootdir/raw/sub-$subject/ses-$session/anat/sub-${subject}_ses-${session}_T1w.nii.gz

[ ! -f $T2in ] && mrcalc $scandir/An-S2/sub-${subject}_ses-${session}_An-S2_*-dhcp8t2tsesense_Ro0.50.nii 0 -max -quiet - | mrconvert - -coord 3 0 -axes 0,1,2 $T2in

has_t1=false
if [ -e $scandir/An-S1/sub-${subject}_ses-${session}_An-S1_*Ro0.50.nii ]; then
  has_t1=true
  [ ! -f $T1in ] && mrcalc $scandir/An-S1/sub-${subject}_ses-${session}_An-S1_*Ro0.50.nii 0 -max -quiet - | mrconvert - -coord 3 0 -axes 0,1,2 $T1in
fi

# ____________________ run pipeline ____________________

set -x
if [ ! -d $struct/workdir/${subject}-${session} ]; then
    echo "running anatomical pipeline for sub-${subject}/ses-${session} on non-defaced images"

    if $has_t1; then
      time docker run --rm -t \
          -u $(id -u):$(id -g) \
          --mount type=bind,source=$rootdir,target=/dhcp_struct \
          biomedia/dhcp-structural-pipeline:$dockertag \
          $subject $session $ga \
          -T2 /dhcp_struct/raw/sub-$subject/ses-$session/anat/sub-${subject}_ses-${session}_T2w.nii.gz \
          -T1 /dhcp_struct/raw/sub-$subject/ses-$session/anat/sub-${subject}_ses-${session}_T1w.nii.gz \
          -no-cleanup -t 8 \
          -d /dhcp_struct/processed_$dockertag/
    else
      time docker run --rm -t \
          -u $(id -u):$(id -g) \
          --mount type=bind,source=$rootdir,target=/dhcp_struct \
          biomedia/dhcp-structural-pipeline:$dockertag \
          $subject $session $ga \
          -T2 /dhcp_struct/raw/sub-$subject/ses-$session/anat/sub-${subject}_ses-${session}_T2w.nii.gz \
          -no-cleanup -t 8 \
          -d /dhcp_struct/processed_$dockertag/
    fi
fi
set +x

# ____________________ run defacing (requires warp from anat pipeline) ____________________

echo "running defacing for sub-${subject}/ses-${session}"

set -x
[ $host == "gpubeastie04" ] && module load fsl

# dilate by 40 pixels (~2cm)
# the BET brainmask is always aligned to the T2
$MIRTK dilate-image \
  $anat/sub-${subject}_ses-${session}_brainmask_bet.nii.gz \
  $tmpdir/${scan}_dilated.nii.gz \
  -connectivity 18 \
  -iterations 40

deface4() {
  in_file=$1
  out_file=$2

  echo deface:
  echo in_file = $in_file
  echo out_file = $out_file

  if [ ! -f $in ]; then
    return
  fi

  if [ -f $out_file ]; then
    return
  fi

  fslmaths \
    $in_file \
    -mul $tmpdir/${scan}_dilated.nii.gz \
    $out_file
}

if [ -f $dofdir/$scan-T2-T1-r.dof.gz ]; then
  $MIRTK invert-dof \
    $dofdir/$scan-T2-T1-r.dof.gz \
    $tmpdir/$scan-T1-T2-r.dof.gz
fi

# deface a volume in T1 or T2 pose
deface2() {
  tn=$1
  in_file=$2
  out_file=$3

  if [ -f $out_file ]; then
    return
  fi

  # if this is T1, we also need to transform with the T1-T2 dof
  if [ $tn == T1 ]; then
    t1_transform="-dofin $tmpdir/$scan-T1-T2-r.dof.gz"
  else
    t1_transform=""
  fi

  # transform to image space
  $MIRTK transform-image \
    $tmpdir/${scan}_dilated.nii.gz \
    $tmpdir/${scan}_dilated_target.nii.gz \
    $t1_transform \
    -target $in_file

  # and mask
  fslmaths \
    $in_file \
    -mul $tmpdir/${scan}_dilated_target.nii.gz \
    $out_file
}

mkdir -p $out

# An-S2 are in T2 pose ... perhaps a mix of axial and sagittal?
echo T2 defacing for $scan ...
for ext in Aq AqPh Di DiPh Re RePh Ro0.50; do
  for filename in $scandir/An-S2/sub-${subject}_ses-${session}_An-S2_*-dhcp*t2tsesense_${ext}.nii; do
    if [ ! -f $filename ]; then
      echo missing $filename
    else
      deface2 T2 $filename $out/$(basename ${filename%.nii}_deface.nii.gz)
    fi
  done
done

# is there a T1 scan? look for An-S1/Ro0.50
if [ -f $scandir/An-S1/sub-${subject}_ses-${session}_An-S1_*_Ro0.50.nii ]; then
  # An-S1 are in T1 pose ... perhaps a mix of axial and sagittal?
  echo T1 defacing for $scan ...
  for ext in Aq AqPh Di DiPh Re RePh Ro0.50; do
    for filename in $scandir/An-S1/sub-${subject}_ses-${session}_An-S1_*-dhcp*t1tseirsense_${ext}.nii; do
      if [ ! -f $filename ]; then
        echo missing $filename
      else
        deface2 T1 $filename $out/$(basename ${filename%.nii}_deface.nii.gz)
      fi
    done
  done
fi

# An-Ve is T2 pose ... maybe?
echo T2 defacing of MPRAGE for $scan ...
for ext in Re RePh; do
  for filename in $scandir/An-Ve/sub-${subject}_ses-${session}_An-Ve_*-dhcp*mpragesense_${ext}.nii; do
    if [ ! -f $filename ]; then
      echo missing $filename
    else
      deface2 T2 $filename $out/$(basename ${filename%.nii}_deface.nii.gz)
    fi
  done
done

# appears to be unused:
# for mode in T1 T2; do
#   in=$workdir/restore/$mode/$scan.nii.gz
#   result=$out/sub-${subject}_ses-${session}_${mode}w.nii.gz
#   deface4 $in $result
# done

# for mode in T1 T2; do
#   in=$workdir/restore/$mode/${scan}_restore.nii.gz
#   result=$out/sub-${subject}_ses-${session}_${mode}w_restore.nii.gz
#   deface4 $in $result
# done
