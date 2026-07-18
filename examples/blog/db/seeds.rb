# frozen_string_literal: true

author = Auth::Repository.find_by_email("writer@example.com")

if !author
  author = Auth::User.new(email: "writer@example.com")
  author.password = "change-this-password"
  author.verify_email
  Auth::Repository.save(author)
elsif !author.email_verified?
  author.verify_email
  Auth::Repository.save(author)
end

unless Posts::Repository.dataset.where(title: "Welcome to Field Notes").any?
  post = Posts::Post.new(
    title: "Welcome to Field Notes",
    body: <<~TEXT.strip,
      This post was created through the same domain API used by the web actions.

      Lunula keeps HTTP translation, business behavior, and persistence
      explicit while allowing them to read together as ordinary Ruby.
    TEXT
    author_id: author.id
  )

  post.publish
  Posts::Repository.save(post)
end
