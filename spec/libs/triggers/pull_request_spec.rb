require "rails_helper"

describe Triggers::PullRequest do
  let(:release) { create(:releases_train_run) }
  let(:working_branch) { Faker::Lorem.word }
  let(:release_branch) { Faker::Lorem.word }
  let(:pr_title) { Faker::Lorem.word }
  let(:pr_description) { Faker::Lorem.word }
  let(:create_payload) { JSON.parse(File.read("spec/fixtures/github/pull_request.json")).with_indifferent_access }
  let(:merge_payload) { JSON.parse(File.read("spec/fixtures/github/merge_pull_request.json")).with_indifferent_access }
  let(:repo_integration) { instance_double(Installations::Github::Api) }
  let(:repo_name) { release.train.app.config.code_repository_name }

  before do
    allow_any_instance_of(described_class).to receive(:repo_integration).and_return(repo_integration)
  end

  describe ".create_and_merge!" do
    it "creates a PR for the release and closes it after merging" do
      allow(repo_integration).to receive(:create_pr!).and_return(create_payload)
      allow(repo_integration).to receive(:merge_pr!).and_return(merge_payload)

      result = described_class.create_and_merge!(
        release: release,
        new_pull_request: release.pull_requests.post_release.open.build,
        to_branch_ref: working_branch,
        from_branch_ref: release_branch,
        title: pr_title,
        description: pr_description
      )

      expect(repo_integration).to have_received(:create_pr!).with(repo_name, working_branch, release_branch, pr_title, pr_description)
      expect(repo_integration).to have_received(:merge_pr!)
      expect(result.ok?).to be(true)
      expect(release.reload.pull_requests.closed.size).to eq(1)
    end

    it "does not create PR and merge it if the PR does not have a diff to create" do
      allow(repo_integration).to receive(:create_pr!).and_raise(Installations::Errors::PullRequestWithoutCommits)
      allow(repo_integration).to receive(:merge_pr!)

      result = described_class.create_and_merge!(
        release: release,
        new_pull_request: release.pull_requests.post_release.open.build,
        to_branch_ref: working_branch,
        from_branch_ref: release_branch,
        title: pr_title,
        description: pr_description
      )

      expect(repo_integration).to have_received(:create_pr!).with(repo_name, working_branch, release_branch, pr_title, pr_description)
      expect(repo_integration).not_to have_received(:merge_pr!)
      expect(result.ok?).to be(true)
      expect(release.reload.pull_requests.size).to eq(0)
    end

    it "returns an unsuccessful result if the PR does not have a diff to create and allow without diff is false" do
      allow(repo_integration).to receive(:create_pr!).and_raise(Installations::Errors::PullRequestWithoutCommits)
      allow(repo_integration).to receive(:merge_pr!)

      result = described_class.create_and_merge!(
        release: release,
        new_pull_request: release.pull_requests.post_release.open.build,
        to_branch_ref: working_branch,
        from_branch_ref: release_branch,
        title: pr_title,
        description: pr_description,
        allow_without_diff: false
      )

      expect(repo_integration).to have_received(:create_pr!).with(repo_name, working_branch, release_branch, pr_title, pr_description)
      expect(repo_integration).not_to have_received(:merge_pr!)
      expect(result.ok?).to be(false)
      expect(release.reload.pull_requests.size).to eq(0)
    end

    it "does not close the PR if the merge fails" do
      allow(repo_integration).to receive(:create_pr!).and_return(create_payload)
      allow(repo_integration).to receive(:merge_pr!).and_raise(Installations::Errors::PullRequestNotMergeable)

      result = described_class.create_and_merge!(
        release: release,
        new_pull_request: release.pull_requests.post_release.open.build,
        to_branch_ref: working_branch,
        from_branch_ref: release_branch,
        title: pr_title,
        description: pr_description
      )

      expect(repo_integration).to have_received(:create_pr!).with(repo_name, working_branch, release_branch, pr_title, pr_description)
      expect(repo_integration).to have_received(:merge_pr!)
      expect(result.ok?).to be(false)
      expect(release.reload.pull_requests.open.size).to eq(1)
    end
  end
end