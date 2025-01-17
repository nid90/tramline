require "rails_helper"

describe Triggers::PostRelease::ParallelBranches do
  let(:release) { create(:releases_train_run, branch_name: "production") }

  it ".call" do
    skip "not implemented yet"

    repo_integration = instance_double(Installations::Github::Api)
    allow_any_instance_of(described_class).to receive(:repo_integration).and_return(repo_integration)
    allow(repo_integration).to receive(:create_pr!).and_return({number: 1})
    allow(repo_integration).to receive(:merge_pr!)
    allow(release.train).to receive(:create_tag!)

    described_class.call(release)
    expect(release.status).to be_eql("finished")
    expect(release.train).to have_received(:create_tag!).with(branch: "production")
    expect(repo_integration).to have_received(:create_pr!).with(nil,
      "dev",
      nil,
      "[Release kickoff] 1.2.0",
      "New release train train triggered.\nThe dev branch has been merged into production branch, as per Release with Backmerge branching strategy.\n")
    expect(repo_integration).to have_received(:merge_pr!).with(any_args)
  end
end
