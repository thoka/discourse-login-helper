class AddDestinationUrlToEmailToken < ActiveRecord::Migration[7.0]
  def change
    add_column :email_tokens, :destination_url, :string
  end
end
