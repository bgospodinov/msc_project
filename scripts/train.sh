#!/bin/bash
#SBATCH -N 1	  # nodes requested
#SBATCH -n 1	  # tasks requested
#SBATCH --gres=gpu:1
#SBATCH --gres-flags=enforce-binding
#SBATCH --mem=8000  # memory in Mb

# Author: Bogomil Gospodinov


# if slurm job id is unavailable use datetime for logging purposes
datetime_name=`date +%s`

set -x

# path to original dataset (relative to root dir of project)
original_dataset=${original_dataset:=data/datasets/MorphoData-NewSplit}
PYTHON_INTERPRETER_DEFAULT_PATH=$(which python)
CONDA_DEFAULT_ENV_NAME=$CONDA_DEFAULT_ENV
CONDA_PREFIX_PATH=$CONDA_PREFIX
PYTHON_INTERPRETER_PATH=$CONDA_PREFIX/bin/python
SLURMD_NODENAME=${SLURMD_NODENAME}
SLURM_JOB_NODELIST=${SLURM_JOB_NODELIST}
SLURM_JOB_PARTITION=${SLURM_JOB_PARTITION}
SLURM_ENABLED=${SLURM_JOB_ID:+1}
SLURM_JOB_ID=${SLURM_JOB_ID:=$datetime_name}
SLURM_ORIGINAL_JOB_ID=${SLURM_ORIGINAL_JOB_ID}
skip_resume_training=${skip_resume_training:+1}
seed=${seed:=0}

# path to nematus (relative to root dir project)
nematus=${nematus:=nematus}

set +x

echo $PATH
conda list

if [[ -z "$SLURM_ORIGINAL_JOB_ID" ]]; then
	set -x
	
	# transform params
	tag_unit=${tag_unit:=char}
	word_unit=${word_unit:=char}
	context_unit=${context_unit:=char}
	context_span=${context_span:=0}
	context_size=${context_size:=20}
	char_n_gram_mode=${char_n_gram_mode:=1}
	transform_mode=${transform_mode:=word_and_context}
	context_tags=${context_tags:=none}
	tag_first=${tag_first:+--tag_first}
	bpe_operations=${bpe_operations:=500}
	output_dir=${TMPDIR:-data/input/}
	word_column_index=${word_column_index:=0}
	lemma_column_index=${lemma_column_index:=1}
	tag_column_index=${tag_column_index:=2}

	# training params
	patience=${patience:=2}
	optimizer=${optimizer:=adadelta}
	learning_rate=${learning_rate:=1.0}
	enc_depth=${enc_depth:=3}
	dec_depth=${dec_depth:=1}
	embedding_size=${embedding_size:=300}
	state_size=${state_size:=300}
	dropout_embedding=${dropout_embedding:=0.2}
	dropout_hidden=${dropout_hidden:=0.3}
	dropout_source=${dropout_source:=0.0}
	dropout_target=${dropout_target:=0.0}
	output_hidden_activation=${output_hidden_activation:=tanh}
	decay_c=${decay_c:=0.0}
	maxlen=${maxlen:=120}
	translation_maxlen=${translation_maxlen:=50}
	sentence_size=${sentence_size:=50}
	valid_burn_in=${valid_burn_in:=10000}
	valid_freq=${valid_freq:=3000}
	batch_size=${batch_size:=60}
	valid_batch_size=${valid_batch_size:=25}
	beam_size=${beam_size:=12}
	

	set +x

	if [[ -n "$SLURM_ENABLED" ]]; then
		/usr/bin/time -f %e cp -urv ${original_dataset} ${TMPDIR}
		set -x
		original_dataset=${TMPDIR}/${original_dataset##*/}
		set +x
	fi

	echo Transforming
	for partition in training dev test ; do
		input_file=${original_dataset}/${partition}.txt
		echo Transforming ${input_file}
		set -x

		transform_folder_path=$( /usr/bin/time -f %e $PYTHON_INTERPRETER_PATH -m data.transform_ud \
		--input $input_file \
		--output $output_dir \
		--mode $transform_mode \
		--sentence_size $sentence_size \
		--context_tags $context_tags \
		--context_span $context_span \
		--word_unit $word_unit \
		--tag_unit $tag_unit \
		$tag_first \
		--context_unit $context_unit \
		--bpe_operations $bpe_operations \
		--context_size $context_size \
		--char_n_gram_mode $char_n_gram_mode \
		--transform_appendix $SLURM_JOB_ID \
		--word_column_index $word_column_index \
		--lemma_column_index $lemma_column_index \
		--tag_column_index $tag_column_index \
		| sed -n 1p )

		set +x
		
		[ -z "$transform_folder_path" ] && echo "No transform folder found or generated. Exiting." && exit
	done

	if [[ -n "$SLURM_ENABLED" ]]; then
		term_handler()
		{
			echo "function term_handler called. Exiting..."
			# do whatever cleanup you want here
			rm -rfv $transform_folder_path
			echo $transform_folder_path deleted
		}
		# associate the function "term_handler" with the TERM or EXIT signals
		trap 'term_handler' TERM EXIT
	fi

	set -x
	transform_folder_name=$( basename $transform_folder_path )
	model_name=m${enc_depth}_${dec_depth}_${embedding_size}_${state_size}_${output_hidden_activation}_${decay_c}_${dropout_embedding}_${dropout_hidden}_${dropout_source}_${dropout_target}_${optimizer}_${learning_rate}
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
		/usr/bin/time -f %e $PYTHON_INTERPRETER_PATH ${nematus}/data/build_dictionary.py ${model_dir}/data/training_source ${model_dir}/data/training_target
	else
		echo Dictionaries found and reused
	fi

	set -e

	echo Training
	/usr/bin/time -f %e $PYTHON_INTERPRETER_PATH ${nematus}/nematus/nmt.py \
	--model ${model_dir}/${SLURM_JOB_ID}/model.npz \
	--source_dataset ${model_dir}/data/training_source \
	--target_dataset ${model_dir}/data/training_target \
	--valid_source_dataset ${model_dir}/data/dev_source \
	--valid_target_dataset ${model_dir}/data/dev_target \
	--keep_train_set_in_memory \
	--patience ${patience} \
	--validFreq $valid_freq \
	--validBurnIn $valid_burn_in \
	--saveFreq 0 \
	--maxlen $maxlen \
	--translation_maxlen $translation_maxlen \
	--dispFreq 100 \
	--sampleFreq 100 \
	--beam_size ${beam_size} \
	--batch_size $batch_size \
	--valid_batch_size $valid_batch_size \
	--use_dropout \
	--dropout_embedding ${dropout_embedding} \
	--dropout_hidden ${dropout_hidden} \
	--dropout_source ${dropout_source} \
	--dropout_target ${dropout_target} \
	--optimizer ${optimizer} \
	--learning_rate ${learning_rate} \
	--decay_c ${decay_c} \
	--enc_depth $enc_depth \
	--dec_depth $dec_depth \
	--embedding_size ${embedding_size} \
	--state_size ${state_size} \
	--output_hidden_activation ${output_hidden_activation} \
	--random_seed "${seed}" \
	--dictionaries ${model_dir}/data/training_source.json ${model_dir}/data/training_target.json

else
	set -e

	echo Reloading model for job $SLURM_ORIGINAL_JOB_ID
	set -x
	SLURM_JOB_ID=$SLURM_ORIGINAL_JOB_ID
	model_dir=$( find models/ -path "*/$SLURM_ORIGINAL_JOB_ID" | head -n 1 )
	model_dir=${model_dir%/*}
	set +x
	if [ -z "$model_dir" ]; then
		echo No models for $SLURM_ORIGINAL_JOB_ID found in models/.
		exit -1
	fi

	if [ -z "$skip_resume_training" ]; then
		echo Resuming training
		/usr/bin/time -f %e $PYTHON_INTERPRETER_PATH ${nematus}/nematus/nmt.py \
		--model ${model_dir}/${SLURM_JOB_ID}/model.npz \
		--load_model_config \
		--reload latest_checkpoint
	else
		echo Skipping over training...
	fi
	
	log_file=$(find logs/ -path \*${SLURM_JOB_ID}.log -print -quit)
	log_file=${log_file:="logs/%x.%j.log"}
	echo $log_file found
	set -x
	transform_mode=`grep "transform_mode" $log_file | head -n 1 | sed 's/.*=//'`
	transform_mode=${transform_mode:='word_and_context'}
	set +x
fi

echo Translating dev set
/usr/bin/time -f %e $PYTHON_INTERPRETER_PATH ${nematus}/nematus/translate.py \
-m ${model_dir}/${SLURM_JOB_ID}/model.npz \
-i ${model_dir}/data/dev_source \
-o ${model_dir}/data/dev_hypothesis.${SLURM_JOB_ID} \
-k 0 -n -p 1 -v

if [ "$transform_mode" = "sentence_to_sentence" ] ; then
	set -x
	pred_ground_file=${model_dir}/data/dev_source
	score_ground_file=${original_dataset}/dev.txt
	set +x
else
	set -x
	pred_ground_file=${original_dataset}/dev.txt
	score_ground_file=$pred_ground_file
	set +x
fi

echo Postprocessing dev predictions
/usr/bin/time -f %e $PYTHON_INTERPRETER_PATH -m data.postprocess_nematus ${model_dir}/data/dev_hypothesis.${SLURM_JOB_ID} $pred_ground_file --${transform_mode} > ${model_dir}/data/dev_prediction.${SLURM_JOB_ID}

echo Calculating score
/usr/bin/time -f %e $PYTHON_INTERPRETER_PATH -m analysis.score_prediction ${model_dir}/data/dev_prediction.${SLURM_JOB_ID} --ground $score_ground_file > ${model_dir}/data/dev_score.${SLURM_JOB_ID}

echo Concatenating
cat ${model_dir}/data/dev_score.* > ${model_dir}/data/dev_scores

echo Averaging
/usr/bin/time -f %e $PYTHON_INTERPRETER_PATH -m analysis.average ${model_dir}/data/dev_scores > ${model_dir}/data/dev_avg_score
