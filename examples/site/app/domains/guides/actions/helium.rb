# frozen_string_literal: true

module Guides
  module Helium
    def self.respond(_context, _params)
      {
        samples: {
          filter: <<~ERB,
            <section @data='{ "productQuery": "", "stockOnly": false }'>
              <input @bind="productQuery" placeholder="Search products">
              <label>
                <input type="checkbox" @bind="stockOnly">
                Only show in-stock products
              </label>

              <article @visible="'factory records tote'.includes(productQuery.toLowerCase()) && (!stockOnly || true)">
                Factory Records Tote
              </article>
            </section>
          ERB
          inline_edit: <<~ERB,
            <article @data='{ "editingTitle": false, "recordTitle": "Blue Monday", "draftTitle": "Blue Monday" }'>
              <h3 id="record-title" @visible="!editingTitle" @text="recordTitle">Blue Monday</h3>
              <button @visible="!editingTitle" @click="editingTitle = true">Edit</button>

              <form
                method="post"
                action="/records/1"
                @ref="titleForm"
                @visible="editingTitle"
              >
                <input name="title" @bind="draftTitle">
                <button
                  @post.prevent="/guides/helium/title-preview"
                  @params="new FormData($titleForm)"
                  @target="#record-title:replace"
                  @click="editingTitle = false"
                >Save title</button>
              </form>
            </article>
          ERB
          modal: <<~ERB,
            <div @data='{ "commentOpen": false }'>
              <button @click="commentOpen = true">New comment</button>
              <dialog :open="commentOpen">
                <form
                  method="post"
                  action="/comments"
                  @ref="commentForm"
                >
                  <textarea name="body" @bind="commentBody"></textarea>
                  <button type="button" @click="commentOpen = false">Cancel</button>
                  <button
                    @post.prevent="/guides/helium/comment-preview"
                    @params="new FormData($commentForm)"
                    @target="#comment-result:append"
                    @click="commentOpen = false, commentBody = ''"
                  >Post comment</button>
                </form>
              </dialog>
              <div id="comment-result"></div>
            </div>
          ERB
          dependent_fields: <<~ERB,
            <fieldset @data='{ "product_kind": "physical", "physical_quantity": 1, "digital_downloads": 3 }'>
              <select name="kind" @change="product_kind = $event.target.value">
                <option value="physical">Physical</option>
                <option value="digital">Digital</option>
              </select>

              <label @visible="product_kind === 'physical'">
                Stock count
                <input name="quantity" type="number" @input="physical_quantity = $event.target.value">
              </label>

              <label @visible="product_kind === 'digital'">
                Download limit
                <input name="download_limit" type="number" value="3" @input="digital_downloads = $event.target.value">
              </label>

              <p>
                <strong @visible="product_kind === 'physical'" @text="physical_quantity + ' physical copies'"></strong>
                <strong @visible="product_kind === 'digital'" @text="digital_downloads + ' downloads per purchase'"></strong>
              </p>
            </fieldset>
          ERB
          preview: <<~ERB,
            <section @data='{ "previewBody": "" }'>
              <textarea name="body" @bind="previewBody"></textarea>
              <aside @visible="previewBody.length > 0">
                Preview: <span @text="previewBody"></span>
              </aside>
            </section>
          ERB
          pending: <<~ERB,
            <section
              @data='{ "timestamp": 0 }'
              @import="/assets/time_ago.js"
              @init="start_time_ago_clock($data)"
            >
              <form method="post" action="/messages" @ref="messageForm">
                <input name="message" placeholder="Message" required @bind="messageText">
                <button
                  @post.prevent="/guides/helium/post-preview"
                  @params="new FormData($messageForm)"
                  @target="#post-result:append"
                >Post message</button>
                <div id="post-result"></div>
              </form>
            </section>
          ERB
        }
      }
    end
  end
end
