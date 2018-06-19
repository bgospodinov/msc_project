#!/bin/bash
#SBATCH -N 1	  # nodes requested
#SBATCH -n 1	  # tasks requested
#SBATCH --gres-flags=enforce-binding
#SBATCH --gres=gpu:1
#SBATCH --mem=8000  # memory in Mb

# Author: Bogomil Gospodinov
[ -z "$model_run_dir" ] && echo "Export full model_run_dir." && exit

# if slurm job id is unavailable use datetime for logging purposes
datetime_name=`date '+%Y-%m-%d_%H:%M:%S'`

set -x

SLURM_JOB_ID=${SLURM_JOB_ID:=$datetime_name}

# path to nematus (relative to root dir project)
nematus=${nematus:=nematus}

model_run_dir=${model_run_dir}
model_dir=${model_run_dir%/*}
input_path=${input_path:=${model_dir}/data/dev_source}
output_path=${output_path:=${model_dir}/data/dev_hypothesis}

set +x

echo Translating

python ${nematus}/nematus/translate.py \
-m ${model_run_dir}/model.npz \
-i ${input_path} \
-o ${output_path} \
-k 12 -n -p 1 -v