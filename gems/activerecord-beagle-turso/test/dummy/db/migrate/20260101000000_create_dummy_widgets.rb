# frozen_string_literal: true

class CreateDummyWidgets < ActiveRecord::Migration[8.1]
  def change
    create_table :dummy_widgets do |t|
      t.string :name, null: false
      t.integer :qty, default: 0
      t.timestamps
    end
  end
end
