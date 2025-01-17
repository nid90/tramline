# == Schema Information
#
# Table name: app_store_integrations
#
#  id         :uuid             not null, primary key
#  p8_key     :string
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  issuer_id  :string
#  key_id     :string
#
class AppStoreIntegration < ApplicationRecord
  has_paper_trail

  InvalidTransformations = Class.new(StandardError)

  encrypts :key_id, deterministic: true
  encrypts :p8_key, deterministic: true
  encrypts :issuer_id, deterministic: true

  include Providable
  include Displayable
  include Loggable

  delegate :app, to: :integration
  delegate :cache, to: Rails
  delegate :refresh_external_app, to: :app

  validate :correct_key, on: :create
  before_create :set_external_details_on_app

  attr_accessor :p8_key_file

  after_create_commit :refresh_external_app

  DEFAULT_PHASED_RELEASE_SEQUENCE = [1, 2, 5, 10, 20, 50, 100]

  CHANNELS_TRANSFORMATIONS = {
    id: :id,
    name: :name
  }

  BUILD_TRANSFORMATIONS = {
    external_id: :id,
    name: :version_string,
    build_number: :build_number,
    status: :beta_external_state,
    added_at: :uploaded_date
  }

  APP_TRANSFORMATIONS = {
    id: :id,
    name: :name,
    bundle_id: :bundle_id
  }

  CHANNEL_DATA_TRANSFORMATIONS = {
    name: :name,
    releases: {
      builds: {
        version_string: :version_string,
        status: :status,
        build_number: :build_number,
        id: :id,
        release_date: :release_date
      }
    }
  }

  RELEASE_TRANSFORMATIONS = {
    external_id: :build_id,
    status: :app_store_state,
    build_number: :build_number,
    name: :version_name,
    added_at: :created_date,
    phased_release_day: [:phased_release, :current_day_number],
    phased_release_status: [:phased_release, :phased_release_state]
  }

  PROD_CHANNEL = {id: :app_store, name: "App Store (production)", is_production: true}

  unless Set.new(BUILD_TRANSFORMATIONS.keys).superset?(Set.new(ExternalRelease.minimum_required))
    raise InvalidTransformations
  end

  unless Set.new(RELEASE_TRANSFORMATIONS.keys).superset?(Set.new(ExternalRelease.minimum_required))
    raise InvalidTransformations
  end

  def access_key
    OpenSSL::PKey::EC.new(p8_key)
  end

  def installation
    Installations::Apple::AppStoreConnect::Api.new(app.bundle_identifier, key_id, issuer_id, access_key)
  end

  def creatable?
    true
  end

  def connectable?
    false
  end

  def store?
    true
  end

  def controllable_rollout?
    false
  end

  def find_build(build_number)
    GitHub::Result.new { build_info(installation.find_build(build_number, BUILD_TRANSFORMATIONS)) }
  end

  def find_release(build_number)
    GitHub::Result.new { release_info(installation.find_release(build_number, RELEASE_TRANSFORMATIONS)) }
  end

  def find_live_release
    GitHub::Result.new { release_info(installation.find_live_release(RELEASE_TRANSFORMATIONS)) }
  end

  def release_to_testflight(beta_group_id, build_number)
    GitHub::Result.new { installation.add_build_to_group(beta_group_id, build_number) }
  end

  def prepare_release(build_number, version, is_phased_release)
    GitHub::Result.new { installation.prepare_release(build_number, version, is_phased_release) }
  end

  def submit_release(build_number)
    GitHub::Result.new { installation.submit_release(build_number) }
  end

  def start_release(build_number)
    GitHub::Result.new { installation.start_release(build_number) }
  end

  def complete_phased_release
    GitHub::Result.new { release_info(installation.complete_phased_release(RELEASE_TRANSFORMATIONS)) }
  end

  def find_app
    @find_app ||= installation.find_app(APP_TRANSFORMATIONS)
  end

  def channel_data
    installation.current_app_status(CHANNEL_DATA_TRANSFORMATIONS)
  end

  def build_channels(with_production:)
    sliced =
      cache.fetch(build_channels_cache_key, expires_in: 1.hour) do
        installation
          .external_groups(CHANNELS_TRANSFORMATIONS)
          .push(PROD_CHANNEL)
          .map { |channel| channel.slice(:id, :name, :is_production) }
      end

    return sliced if with_production
    sliced.reject { |channel| channel[:is_production] }
  end

  def build_channels_cache_key
    "app/#{app.id}/app_store_integration/#{id}/build_channels"
  end

  def to_s
    "app_store"
  end

  def build_info(build_info)
    TestFlightInfo.new(build_info)
  end

  def release_info(build_info)
    AppStoreReleaseInfo.new(build_info)
  end

  def correct_key
    find_app.present?
  rescue Installations::Apple::AppStoreConnect::Error => ex
    errors.add(:key_id, ex.reason)
  end

  def set_external_details_on_app
    app.set_external_details(find_app[:id])
  end

  class TestFlightInfo
    def initialize(build_info)
      raise ArgumentError, "build_info must be a Hash" unless build_info.is_a?(Hash)
      @build_info = build_info
    end

    attr_reader :build_info

    MISSING_EXPORT_COMPLIANCE = "MISSING_EXPORT_COMPLIANCE"
    EXPIRED = "EXPIRED"
    BETA_REJECTED = "BETA_REJECTED"
    PROCESSING_EXCEPTION = "PROCESSING_EXCEPTION"
    BETA_APPROVED = "BETA_APPROVED"
    IN_BETA_TESTING = "IN_BETA_TESTING"

    def attributes
      build_info
    end

    def success?
      build_info[:status].in?(
        [
          BETA_APPROVED,
          IN_BETA_TESTING
        ]
      )
    end

    def failed?
      build_info[:status].in?(
        [
          BETA_REJECTED,
          PROCESSING_EXCEPTION,
          MISSING_EXPORT_COMPLIANCE,
          EXPIRED
        ]
      )
    end
  end

  class AppStoreReleaseInfo
    def initialize(release_info)
      raise ArgumentError, "release_info must be a Hash" unless release_info.is_a?(Hash)
      @release_info = release_info
    end

    attr_reader :release_info

    READY_FOR_SALE = "READY_FOR_SALE"
    PENDING_DEVELOPER_RELEASE = "PENDING_DEVELOPER_RELEASE"
    DEVELOPER_REJECTED = "DEVELOPER_REJECTED"
    DEVELOPER_REMOVED_FROM_SALE = "DEVELOPER_REMOVED_FROM_SALE"
    REJECTED = "REJECTED"
    METADATA_REJECTED = "METADATA_REJECTED"
    INVALID_BINARY = "INVALID_BINARY"
    PHASED_RELEASE_COMPLETE = "COMPLETE"

    def attributes
      release_info.except(:phased_release_day, :phased_release_status)
    end

    def phased_release_stage
      return DEFAULT_PHASED_RELEASE_SEQUENCE.count.pred if phased_release_complete?
      release_info[:phased_release_day].pred
    end

    def phased_release_complete?
      release_info[:phased_release_status] == PHASED_RELEASE_COMPLETE
    end

    def live?(build_number)
      release_info[:build_number] == build_number && release_info[:status] == READY_FOR_SALE
    end

    def success?
      release_info[:status].in?(
        [
          PENDING_DEVELOPER_RELEASE
        ]
      )
    end

    def failed?
      release_info[:status].in?(
        [
          REJECTED,
          INVALID_BINARY,
          DEVELOPER_REJECTED,
          METADATA_REJECTED
        ]
      )
    end
  end
end
