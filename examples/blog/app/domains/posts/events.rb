# frozen_string_literal: true

module Posts
  module Events
    Published = Data.define(:post_id, :author_id, :occurred_at)
    Archived = Data.define(:post_id, :author_id, :occurred_at)
  end
end
