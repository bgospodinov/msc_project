if __name__ == "__main__":
    import os
    import sys
    sys.path.append(os.path.join(os.path.dirname(__file__), '..'))
    from config import config
    import argparse
    import pandas as pd
    from helper import preprocess_dataset

    cols = list(config["DATASET"]["COLUMNS"].values())

    parser = argparse.ArgumentParser()
    parser.add_argument("--training", help="training file name", type=str,
                        default=os.path.join(os.path.pardir, "data", config["DATASET"]["FOLDER"], "training.txt"))
    parser.add_argument("prediction", help="file name of predictions", type=str)
    parser.add_argument("ground", help="ground truth file name", type=str)
    args = parser.parse_args()

    dfs = {}

    for partition in vars(args):
        dfs[partition] = preprocess_dataset(pd.read_csv(vars(args)[partition], sep='\s+', names=cols))

    assert dfs["prediction"].shape[0] == dfs["ground"].shape[0], "More rows predicted than necessary"

    def print_results(match):
        print(match["lemma_match"].value_counts(normalize=True))
        print(match["tag_match"].value_counts(normalize=True))
        print(match["joint_match"].value_counts(normalize=True))
        # prediction_match[prediction_match["joint_match"] == False]
        print("\n")

    print(" Prediction results for {} ".format(args.prediction).upper().center(config["PPRINT"]["TITLE_LENGTH"], config["PPRINT"]["TITLE_CH"]))
    print("\n")
    print("All tokens")
    prediction_match = dfs["prediction"].join(dfs["ground"], lsuffix='_prediction', rsuffix='_truth')
    prediction_match['lemma_match'] = prediction_match.apply(lambda row: row.lemma_prediction == row.lemma_truth,
                                       axis=1)
    prediction_match['tag_match'] = prediction_match.apply(lambda row: row.tag_prediction == row.tag_truth, axis=1)
    prediction_match['joint_match'] = prediction_match.apply(
        lambda row: row.tag_prediction == row.tag_truth and row.lemma_prediction == row.lemma_truth, axis=1)
    print_results(prediction_match)
    print("\n")

    print("Unseen tokens")
    training_words = dfs["training"]["word"].unique()
    prediction_match['seen'] = prediction_match.apply(lambda row: row.word_prediction in training_words, axis=1)
    print_results(prediction_match[prediction_match['seen'] == False])
    print("\n")

    print("Ambiguous tokens")
    ambiguous_index = dfs["ground"].groupby("word").nunique()["lemma"] > 1
    ambiguous_words = ambiguous_index.where(lambda x: x).dropna().index.tolist()
    prediction_match['ambiguous'] = prediction_match.apply(lambda row: row.word_prediction in ambiguous_words, axis=1)
    print_results(prediction_match[prediction_match['ambiguous'] == True])
    print("\n")