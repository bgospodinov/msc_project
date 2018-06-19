#!/bin/bash
#SBATCH -N 1	  # nodes requested
#SBATCH -n 1	  # tasks requested
#SBATCH --gres=gpu:1
#SBATCH --gres-flags=enforce-binding
#SBATCH --mem=8000  # memory in Mb

# Author: Bogomil Gospodinov
# path to original dataset (relative to root dir of project)
original_dataset=data/datasets/MorphoData-NewSplit

# if slurm job id is unavailable use datetime for logging purposes
datetime_name=`date '+%Y-%m-%d_%H:%M:%S'`

set -x

SLURM_ENABLED=${SLURM_JOB_ID:+1}
SLURM_JOB_ID=${SLURM_JOB_ID:=$datetime_name}

# path to nematus (relative to root dir project)
nematus=${nematus:=nematus}

# transform params
tag_unit=${tag_unit:=char}
context_unit=${context_unit:=char}
context_size=${context_size:=20}
char_n_gram=${char_n_gram:=1}

# training params
patience=${patience:=2}
enc_depth=${enc_depth:=2}
dec_depth=${dec_depth:=2}
embedding_size=${embedding_size:=300}
state_size=${state_size:=100}

set +x

if [[ -n "$SLURM_ENABLED" ]]; then
	set -x
	$tmp_original_dataset=${TMPDIR}/${original_dataset##*/}
	set +x
	/usr/bin/time -f %e cp -urv ${original_dataset} $tmp_original_dataset
	set -x
	$original_dataset=$tmp_original_dataset
	set +x
fi

echo Transforming
for partition in training dev test ; do
	input_file=${original_dataset}/${partition}.txt
	echo Transforming ${input_file}
	set -x
	
	transform_folder_path=$( /usr/bin/time -f %e python -m data.transform_ud \
	--input $input_file \
	--output $original_dataset \
	--tag_unit $tag_unit \
	--context_unit $context_unit \
	--context_size $context_size \
	--char_n_gram $char_n_gram \
	--transform_appendix $SLURM_JOB_ID \
	| sed -n 1p )
	
	set +x
	
	[ -z "$transform_folder_path" ] && echo "No transform folder found or generated. Exiting." && exit
done

set -x
transform_folder_name=$( basename $transform_folder_path )
model_name=m${enc_depth}_${dec_depth}_${embedding_size}_${state_size}
model_dir=models/${transform_folder_name%.*}/$model_name
set +x

echo Copying data
mkdir -p models/
mkdir -p $model_dir
mkdir -p $model_dir/${SLURM_JOB_ID}
mkdir -p $model_dir/data

/usr/bin/time -f %e cp -n $transform_folder_path/* $model_dir/data/

# build dictionaries only if they dont exist
if [[ ! -f $model_dir/data/training_source.json && ! -f $model_dir/data/training_target.json ]]; then
	echo Building dictionaries
	/usr/bin/time -f %e python ${nematus}/data/build_dictionary.py ${model_dir}/data/training_source ${model_dir}/data/training_target
else
	echo Dictionaries found and reused
fi

echo Training
/usr/bin/time -f %e python ${nematus}/nematus/nmt.py \
--model ${model_dir}/${SLURM_JOB_ID}/model.npz \
--source_dataset ${model_dir}/data/training_source \
--target_dataset ${model_dir}/data/training_target \
--valid_source_dataset ${model_dir}/data/dev_source \
--valid_target_dataset ${model_dir}/data/dev_target \
--keep_train_set_in_memory \
--patience ${patience} \
--validFreq 3000 \
--saveFreq 0 \
--maxlen 50 \
--dispFreq 100 \
--sampleFreq 100 \
--batch_size 60 \
--use_dropout \
--optimizer "adadelta" \
--enc_depth $enc_depth \
--dec_depth $dec_depth \
--embedding_size ${embedding_size} \
--state_size ${state_size} \
--dictionaries ${model_dir}/data/training_source.json ${model_dir}/data/training_target.json

echo Translating dev set
/usr/bin/time -f %e python ${nematus}/nematus/translate.py \
-m ${model_dir}/${SLURM_JOB_ID}/model.npz \
-i ${model_dir}/data/dev_source \
-o ${model_dir}/data/dev_hypothesis.${SLURM_JOB_ID} \
-k 12 -n -p 1 -v

echo Postprocessing dev predictions
/usr/bin/time -f %e python -m data.postprocess_nematus ${model_dir}/data/dev_hypothesis.${SLURM_JOB_ID} data/datasets/MorphoData-NewSplit/dev.txt > ${model_dir}/data/dev_prediction.${SLURM_JOB_ID}

echo Calculating score
/usr/bin/time -f %e python -m analysis.score_prediction ${model_dir}/data/dev_prediction.${SLURM_JOB_ID} >> ${model_dir}/data/dev_scores

echo Averaging
/usr/bin/time -f %e python -m analysis.average ${model_dir}/data/dev_scores > ${model_dir}/data/dev_avg_score