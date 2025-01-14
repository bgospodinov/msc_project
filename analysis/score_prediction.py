#!/usr/bin/env python

__author__ = "Bogomil Gospodinov"
__email__ = "s1312650@sms.ed.ac.uk"
__status__ = "dev"

if __name__ == "__main__":
    import os
    import sys
    sys.path.append(os.path.join(os.path.dirname(__file__), '..'))
    from config import config
    import argparse
    import pandas as pd
    import numpy as np
    from data.preprocess_ud import preprocess_dataset_for_train, preprocess_dataset_for_eval

    cols = np.array(list(config["DATASET"]["COLUMNS"].values()))

    #BTB baselines/lemming/predictions/btb/bg-dev-pred-py.txt --ground data/datasets/MorphoData-NewSplit/dev.txt
    #UD baselines/lemming/predictions/ud/bg-dev-pred-py.txt --ground baselines/lemming/data/UD_Bulgarian-BTB/bg-ud-dev.conllu.conv
    #hypertune_word_and_context "E:\msc_backup\MorphoData-NewSplit_wchar_tchar_20u_cchar_n1__30062018\m3_1_300_300_tanh_0.0_0.2_0.3_0.0_0.0_adadelta_1.0\data\dev_prediction.131784"
    #context_word_and_context "E:\msc_backup\MorphoData-NewSplit_wchar_tchar_10u_cbpe_n5000\m3_1_300_300_tanh_0.0_0.2_0.3_0.0_0.0_adadelta_1.0\data\dev_prediction.137598"
    #hypertune_sentence_to_sentence "E:\msc_backup\MorphoData-NewSplit_wchar_tchar_n1\m1_1_400_300_tanh_0.0_0.1_0.2_0.0_0.0_adadelta_1.0\data\dev_prediction.140973"
    # "E:\msc_backup\MorphoData-NewSplit_wchar_tword_20u_cchar_n1\m3_1_300_300_tanh_0.0_0.2_0.3_0.0_0.0_adadelta_1.0\data\dev_prediction.141028"
    # for fh in ../models/MorphoData-*/*/data/dev_prediction ; do python -m score_prediction ${fh} > ${fh%/*}/dev_score ; done

    #mismatch test
    #k = 1
    #for i, lemma in enumerate(pred_df["lemma"].tolist()):
    #    similarity = similar(lemma, ground_df.iloc[i]["lemma"])
    #    print(i, lemma, ground_df.iloc[i]["lemma"], similarity)
    #    if similarity == 0:
    #        if k == 0:
    #            break
    #        k -= 1

    parser = argparse.ArgumentParser()
    parser.add_argument("--training", help="training file name", type=str,
                        default=os.path.join("data", "datasets", config["DATASET"]["FOLDER"], "training.txt"))
    parser.add_argument("prediction", help="file name of predictions", type=str)
    parser.add_argument("--ground", help="ground truth file name", type=str,
                        default=os.path.join("data", "datasets", config["DATASET"]["FOLDER"], "dev.txt"))
    parser.add_argument("--dataset_cols", help="list of column indices to read from dataset partitions (order doesnt matter)",
                        nargs='+', type=int, default=[0, 1, 2])
    parser.add_argument("--prediction_cols", help="list of column indices to read from prediction file (order doesnt matter)",
                        nargs='+', type=int, default=[0, 1, 2])
    parser.add_argument('--no_postprocessing', dest='postprocess', action='store_false')
    parser.add_argument('--pickle', action='store_true')
    parser.add_argument("--job_name", help="job name when exporting", type=str)
    args = parser.parse_args()

    dfs = {}
    spyder_result = {}

    for partition in ["training", "ground"]:
        dfs[partition] = preprocess_dataset_for_train(pd.read_csv(vars(args)[partition], sep='\s+', skip_blank_lines=(partition != "ground"), names=cols[args.dataset_cols], usecols=args.dataset_cols))\
            .reset_index()

    # add end-of-sentence column to ground truth table
    dfs["ground"]["eos"] = dfs["ground"]["word"].shift(-1).isnull()
    dfs["ground"].drop("index", axis=1, inplace=True)
    dfs["ground"].dropna(inplace=True)
    dfs["ground"] = dfs["ground"].reset_index()

    dfs["prediction"] = pd.read_csv(vars(args)["prediction"], sep='\s+', names=cols[args.prediction_cols], usecols=args.prediction_cols)

    print("{} ? {}".format(dfs["prediction"].shape[0], dfs["ground"].shape[0]), file=sys.stderr)
    assert dfs["prediction"].shape[0] == dfs["ground"].shape[0], "More rows predicted than necessary"

    def print_and_list_results(match):
        res = []
        if match.empty:
            return res
        for metric in ["lemma", "tag", "joint"]:
            res_bins = match["{}_match".format(metric)].value_counts(normalize=True).sort_index(ascending=False)
            if True in res_bins:
                res.append(str(round(res_bins[True], 5)))
            else:
                res.append(0)
            print(res_bins, file=sys.stderr)
        # prediction_match[prediction_match["joint_match"] == False]
        print("{} number of tokens".format(match.shape[0]), file=sys.stderr)
        return res

    excel_results = []
    print(" Prediction results for {} ".format(args.prediction).upper().center(config["PPRINT"]["TITLE_LENGTH"], config["PPRINT"]["TITLE_CH"]), file=sys.stderr)
    print("\n", file=sys.stderr)
    print("All tokens", file=sys.stderr)
    prediction_match = dfs["prediction"].join(dfs["ground"], lsuffix='_prediction', rsuffix='_truth')
    if args.postprocess:
        print("Postprocessing on.", file=sys.stderr)
        prediction_match = preprocess_dataset_for_eval(prediction_match, prediction=True)
    else:
        print("Postprocessing off.", file=sys.stderr)
    prediction_match['lemma_match'] = prediction_match.apply(lambda row: row.lemma_prediction == row.lemma_truth,
                                       axis=1)
    prediction_match['tag_match'] = prediction_match.apply(lambda row: row.tag_prediction == row.tag_truth, axis=1)
    prediction_match['joint_match'] = prediction_match.apply(
        lambda row: row.tag_prediction == row.tag_truth and row.lemma_prediction == row.lemma_truth, axis=1)
    excel_results.extend(print_and_list_results(prediction_match))
    print("\n", file=sys.stderr)

    print("Predicting unseen tokens", file=sys.stderr)
    training_words = dfs["training"]["word"].unique()
    prediction_match['seen_word'] = prediction_match.apply(lambda row: row.word_truth in training_words, axis=1)
    excel_results.extend(print_and_list_results(prediction_match[prediction_match['seen_word'] == False]))
    print("\n", file=sys.stderr)

    print("Ambiguous tokens", file=sys.stderr)
    ambiguous_index_ground = dfs["ground"].groupby("word").nunique()["lemma"] > 1
    ambiguous_index_training = dfs["training"].groupby("word").nunique()["lemma"] > 1
    joint_ambiguous_index = ambiguous_index_ground[ambiguous_index_ground == True].index.union(ambiguous_index_training[ambiguous_index_training == True].index)
    ambiguous_words = joint_ambiguous_index.tolist()
    prediction_match['ambiguous'] = prediction_match.apply(lambda row: row.word_prediction in ambiguous_words, axis=1)
    excel_results.extend(print_and_list_results(prediction_match[prediction_match['ambiguous'] == True]))
    print("\n", file=sys.stderr)

    print(", ".join(excel_results))

    print("Error analysis".upper().center(config["PPRINT"]["TITLE_LENGTH"], config["PPRINT"]["TITLE_CH"]), file=sys.stderr)
    print("Lemmatization error statistics", file=sys.stderr)
    print_and_list_results(prediction_match[prediction_match["lemma_match"] == False])
    print("\n", file=sys.stderr)

    print("Lemmatization error by whether a token is ambiguous (True) or not (False)", file=sys.stderr)
    spyder_result["lemma_error_by_ambiguity_stats"] = prediction_match[(prediction_match["lemma_match"] == False)]["ambiguous"].value_counts(normalize=True).sort_index(ascending=False)
    print(spyder_result["lemma_error_by_ambiguity_stats"], file=sys.stderr)
    print("\n", file=sys.stderr)

    print("Lemmatization error by whether a token is seen (True) or not (False) in training", file=sys.stderr)
    spyder_result["lemma_error_by_seen_stats"] = prediction_match[(prediction_match["lemma_match"] == False)]["seen_word"].value_counts(normalize=True).sort_index(ascending=False)
    print(spyder_result["lemma_error_by_seen_stats"], file=sys.stderr)
    print("\n", file=sys.stderr)

    # how many times did the model manage to predict tags unseen during training
    print("Predicting unseen tags [IGNORED IN RESULTS]", file=sys.stderr)
    training_tags = dfs["training"]["tag"].unique()
    prediction_match['seen_tag'] = prediction_match.apply(lambda row: row.tag_truth in training_tags, axis=1)
    spyder_result["unseen_tag"] = prediction_match[prediction_match['seen_tag'] == False]
    print_and_list_results(spyder_result["unseen_tag"])
    print("\n", file=sys.stderr)

    # how many times did the model predict tags that didnt exist in reality
    print("Predicted non-existent tags [IGNORED IN RESULTS]", file=sys.stderr)
    ground_tags = dfs["ground"]["tag"].unique()
    prediction_match['existent_tag'] = prediction_match.apply(lambda row: row.tag_prediction in training_tags or row.tag_prediction in ground_tags, axis=1)
    spyder_result["existent_tag"] = prediction_match[prediction_match['existent_tag'] == False]
    print_and_list_results(spyder_result["existent_tag"])
    print("\n", file=sys.stderr)

    print("Tagging errors", file=sys.stderr)
    spyder_result["tag_error"] = prediction_match[prediction_match["tag_match"] == False].groupby(["tag_prediction", "tag_truth"])["word_prediction"]\
        .count().sort_index(ascending=True).sort_values(ascending=False)
    print(spyder_result["tag_error"], file=sys.stderr)
    print("\n", file=sys.stderr)
    print("\n", file=sys.stderr)

    print("Lemmatization errors", file=sys.stderr)
    spyder_result["lemma_error"] = prediction_match[prediction_match["lemma_match"] == False].groupby(["lemma_prediction", "lemma_truth"])["word_prediction"]\
                                        .count().sort_index(ascending=True).sort_values(ascending=False)
    print(spyder_result["lemma_error"], file=sys.stderr)
    print("\n", file=sys.stderr)

    print("Lemmatization error among ambiguous tokens", file=sys.stderr)
    spyder_result["lemma_error_by_ambiguity"] = prediction_match[(prediction_match["lemma_match"] == False) & (prediction_match["ambiguous"] == True)].groupby(
        ["lemma_prediction", "lemma_truth"])["word_prediction"].count().sort_index(ascending=True).sort_values(ascending=False)
    print(spyder_result["lemma_error_by_ambiguity"], file=sys.stderr)
    print("\n", file=sys.stderr)

    print("Lemmatization error among unseen tokens", file=sys.stderr)
    spyder_result["lemma_error_by_seen"] = prediction_match[(prediction_match["lemma_match"] == False) & (prediction_match["seen_word"] == False)].groupby(
        ["lemma_prediction", "lemma_truth"])["word_prediction"].count().sort_index(ascending=True).sort_values(ascending=False)
    print(spyder_result["lemma_error_by_seen"], file=sys.stderr)
    print("\n", file=sys.stderr)

    print("Lemmatization errors by tags", file=sys.stderr)
    spyder_result["lemma_error_by_tag"] = prediction_match[prediction_match["lemma_match"] == False].groupby(["tag_prediction", "tag_truth"])["word_prediction"]\
                                               .count().sort_index(ascending=True).sort_values(ascending=False)
    print(spyder_result["lemma_error_by_tag"], file=sys.stderr)
    print("\n", file=sys.stderr)
    print("\n", file=sys.stderr)

    if args.pickle:
        # for easy exporting of spyder data
        try:
            prediction_matches
        except NameError:
            prediction_matches = {}

        try:
            spyder_results
        except NameError:
            spyder_results = {}

        if args.job_name:
            job_name = args.job_name
        else:
            prediction_path_split = args.prediction.split("prediction.")
            if len(prediction_path_split) == 2:
                job_name = prediction_path_split[-1]
            else:
                job_name = "dev"

        prediction_matches[job_name] = prediction_match
        spyder_results[job_name] = spyder_result
