# frozen_string_literal: true

Hacienda.configure_logger(output: File::NULL, level: :warn)
Hacienda.configure_mail(root: APP_ROOT, delivery: :test)
