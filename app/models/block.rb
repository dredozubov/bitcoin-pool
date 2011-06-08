class Block < ActiveRecord::Base
  # We'll mostly want blocks ordered by solving time
  default_scope order("found_at DESC")

  # We need to track how much coins were generated for each block
  before_validation :set_orphan_flag,
    :set_generated,
    :on => :create

  # A block has many contributions from different workers
  # (unless found by a PPS worker, in which case we keep the generated coins)
  has_many :contributions,
    :dependent => :destroy

  # The share that provided the winning solution
  belongs_to :share

  # The worker that provided the block solution
  belongs_to :worker

  validates :found_at,
    :presence => true

  # This is the big endian block hash
  validates :checksum,
    :presence => true,
    :uniqueness => true

  validates :generated,
    :presence => true,
    :numericality => {
      :greater_than_or_equal_to => 25
    },
    :unless => Proc.new { |b| b.orphan? }

  validates :worker,
    :presence => true

  validates :share_id,
    :presence => true

  # Whether the block is actually confirmed and its coins have matured
  def confirmed?
    confirmations >= 120
  end

  # Scope on blocks that have no contributions recorded
  def self.without_contributions
    where("NOT EXISTS (SELECT * FROM `contributions` WHERE `contributions`.`block_id`=`blocks`.`id`) ")
  end

  # Scope on blocks that were generated by non-PPS workers
  def self.pps(should_pps = true)
    where(:pps => should_pps)
  end

  # Returns the ID of the first share in the round
  def first_share_of_round_id
    previous_round_last_share_id = Share.
      where("`shares`.`id` < ?", share.id).
      pps(false).
      where("`shares`.`id` IN (SELECT `blocks`.`share_id` FROM `blocks`)").
      maximum(:id)

    if previous_round_last_share_id
      Share.pps(false).where("`shares`.`id` > ?", previous_round_last_share_id).minimum(:id)
    else
      Share.pps(false).minimum(:id)
    end
  end

  # Splits the generated coins among the contributors
  def split_the_money!
    total_contributed = contributions.sum(:score)

    contributions.each do |c|
      c.update_attribute :amount, ((c.score / total_contributed) * (1.0 - Setting.get(:pooling_fee).to_f) * generated)
    end
  end

  # Records new blocks based on shares that the upstream bitcoin client
  # recognized as a valid block solution
  def self.fetch_new
    Share.where(:upstream_result => "Y").all.each do |share|
      b = BlockHeader.new(share.solution)

      if Block.where(:checksum => b.hash).count.zero?
        Block.create!({
            :found_at => Time.at(b.timestamp),
            :checksum => b.hash,
            :worker => share.worker,
            :share => share,
            :pps => share.worker.pps
          }
        )
      end
    end
  end

  # Updates the block confirmations based on the confirmations of the
  # generation transaction
  def self.update_confirmations
    Block.where("confirmations < ?", 120).each(&:update_confirmations!)
  end

  # Creates contributions based on submitted shares for each round, this
  # is where we calculate the exact rewards (for the normal case)
  # We do not handle contributions for PPS blocks here since we're already
  # paying a fixed amount for these shares
  def self.create_contributions
    Block.
      without_contributions.
      pps(false).
      all.
      each do |block|

      puts "Prowssessing block #{block.checksum}"

      # Change this to account differently for shares, "1" will count 1 for each
      # share regardless of age (vulnerable to pool hopping!)
      scoring_function = Setting.get(:scoring_function)

      Share.relevant_to(block).
        select("`workers`.`username`").
        select("SUM(#{scoring_function}) AS score").
        group("`workers`.`username`").
        all.
        each do |contribution|

        Contribution.create!(
          :block => block,
          :worker => Worker.find_by_username(contribution['username']),
          :score => contribution['score']
        )
      end

      Share.delete_relevant_to!(block)

      block.split_the_money!
    end
  end

  def update_confirmations!
    set_orphan_flag
    set_generated
    self.confirmations = get_generation_tx["confirmations"]
    save!
  end

  
  def my_share(user)
    # TODO : Fuck that user.contributions.sum etc. would be much nicer
    user.workers.blank? ? 0 : contributions.where("worker_id IN (#{user.workers.map(&:id).join(",")})").sum(:amount)
  end

  
  protected

    # Sets the generated attribute with the amount of coins that were generated
    # in that block (including transaction fees)
    def set_generated
      if orphan?
        self.generated = 0
      else
        tx = get_generation_tx
        amount = 0

        if tx["details"] && (tx["details"][0]["category"] == "immature")
          amount = tx["details"][0]["amount"]
        else
          amount = tx["amount"]
        end

        self.generated = amount.to_f
      end
    end

    # Flags the block as orphan if necessary
    def set_orphan_flag
      tx = get_generation_tx
      self.orphan = tx["details"] && (tx["details"][0]["category"] == "orphan")

      # We need to explicitly return true otherwise the callback chain gets halted
      true
    end

    # Gets the JSON data of the generation transaction
    def get_generation_tx
      blk = bitcoin.get_block_by_hash(checksum)

      # This assumes the generation tx is always the first in the tx array
      @generation_tx ||= bitcoin.get_transaction(blk["tx"][0]["hash"])
    end
end


  # TODO : Properly remove stales