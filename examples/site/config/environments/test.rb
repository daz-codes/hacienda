# frozen_string_literal: true

Lunula.configure_logger(output: File::NULL, level: :warn)
Lunula.configure_mail(root: APP_ROOT, delivery: :test)
