# == Schema Information
#
# Table name: staged_rollouts
#
#  id                :uuid             not null, primary key
#  config            :decimal(8, 5)    default([]), is an Array
#  current_stage     :integer
#  status            :string
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  deployment_run_id :uuid             not null, indexed
#
class StagedRollout < ApplicationRecord
  has_paper_trail
  include AASM
  include Loggable

  belongs_to :deployment_run

  validates :current_stage, numericality: {greater_than_or_equal_to: 0, allow_nil: true}

  STATES = {
    created: "created",
    started: "started",
    failed: "failed",
    completed: "completed",
    stopped: "stopped",
    fully_released: "fully_released"
  }

  enum status: STATES
  aasm safe_state_machine_params do
    state :created, initial: true, before_enter: -> { deployment_run.rolloutable? }
    state(*STATES.keys)

    event :start, guard: -> { deployment_run.rolloutable? } do
      transitions from: :created, to: :started
    end

    event :fail do
      transitions from: [:started, :failed, :created], to: :failed
    end

    event :retry, guard: -> { deployment_run.rolloutable? } do
      transitions from: :failed, to: :started
    end

    event :halt, guard: -> { deployment_run.rolloutable? } do
      after { deployment_run.complete! }
      transitions from: [:started, :paused, :failed], to: :stopped
    end

    event :complete do
      after { deployment_run.complete! }
      transitions from: [:failed, :started], to: :completed
    end

    event :full_rollout do
      after { deployment_run.complete! }
      transitions from: [:failed, :started], to: :fully_released
    end
  end

  def update_stage(stage)
    update(current_stage: stage)
    start! if created?
    retry! if failed?
    complete! if finished?
  end

  def last_rollout_percentage
    return Deployment::FULL_ROLLOUT_VALUE if fully_released?
    return if created? || current_stage.nil?
    config[current_stage]
  end

  def next_rollout_percentage
    return config.first if created?
    config[current_stage.succ]
  end

  def finished?
    next_rollout_percentage.nil?
  end

  def next_stage
    created? ? 0 : current_stage.succ
  end

  def move_to_next_stage!
    return if completed? || fully_released?

    deployment_run.on_release(rollout_value: next_rollout_percentage) do |result|
      if result.ok?
        update_stage(next_stage)
      else
        fail!
        elog(result.error)
      end
    end
  end

  def halt_release!
    return if created?
    return if completed? || fully_released?

    deployment_run.on_halt_release! do |result|
      if result.ok?
        halt!
      else
        elog(result.error)
      end
    end
  end

  def fully_release!
    return if created? || completed? || stopped?

    deployment_run.on_fully_release! do |result|
      if result.ok?
        full_rollout!
      else
        elog(result.error)
      end
    end
  end
end
