# frozen_string_literal: true

module Guides
  class PreviewActions < Lunula::Actions
    def title_preview(_context, params)
      response Preview.title(params[:title])
    end

    def comment_preview(_context, params)
      response Preview.comment(params[:body])
    end

    def post_preview(_context, params)
      response Preview.post(message: params[:message], title: params[:title])
    end
  end
end
