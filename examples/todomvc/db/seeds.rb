# frozen_string_literal: true

now = Time.now

[
  ["Learn Lunula", true],
  ["Build TodoMVC with domains", true],
  ["Use too much Helium", false]
].each do |title, completed|
  next if DB[:todos].where(title: title).first

  DB[:todos].insert(
    title: title,
    completed: completed,
    created_at: now,
    updated_at: now
  )
end
