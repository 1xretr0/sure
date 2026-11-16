# frozen_string_literal: true

class SantanderMxItem::SyncCompleteEvent
  attr_reader :santander_mx_item

  def initialize(santander_mx_item)
    @santander_mx_item = santander_mx_item
  end

  # Broadcast sync-complete Turbo updates for the item, its accounts, and family.
  def broadcast
    santander_mx_item.accounts.each(&:broadcast_sync_complete)

    santander_mx_item.family.broadcast_sync_complete
  end
end
