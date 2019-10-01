#!/usr/bin/env ruby

require 'csv'
require 'bigdecimal'
require 'ostruct'

module Heuristics
  class Heuristic
    def call(entry)
      if satisfied?(entry)
        Result.new(result_account(entry), result_title(entry))
      end
    end

    def result_title(entry)
      entry.title
    end
  end

  class AccountHeuristic < Heuristic
    def initialize(account_number, expense_name)
      @account_number = account_number
      @expense_name = expense_name
    end

    def satisfied?(entry)
      entry.account == account_number
    end

    def result_account(_entry)
      expense_name
    end

    attr_reader :account_number, :expense_name
  end

  class ReceiverRegexHeuristic < Heuristic
    def initialize(receiver_regex, account_name, title = nil)
      @receiver_regex = receiver_regex
      @account_name = account_name
      @title = title
    end

    def satisfied?(entry)
      entry.receiver =~ @receiver_regex
    end

    def result_account(_entry)
      @account_name
    end

    def result_title(_entry)
      @title || super
    end
  end

  class TitlePrefixHeuristic < Heuristic
    def initialize(prefix, account_name)
      @prefix = prefix
      @account_name = account_name
    end

    def satisfied?(entry)
      entry.title.start_with?(@prefix)
    end

    def result_account(entry)
      @account_name
    end
  end

  class AccountNumberAndTitleIncludeHeuristic < Heuristic
    def initialize(account_number, title_include_phrase, account_name)
      @account_number = account_number
      @title_include_phrase = title_include_phrase
      @account_name = account_name
    end

    def satisfied?(entry)
      entry.account == @account_number && entry.title.include?(@title_include_phrase)
    end

    def result_account(_entry)
      @account_name
    end
  end

  class CatchAllHeuristic < Heuristic
    def initialize(account_name)
      @account_name = account_name
    end

    def satisfied?(_entry)
      true
    end

    def result_title(entry)
      "#{entry.title} #{entry.receiver}"
    end

    def result_account(_entry)
      @account_name
    end
  end

  class Result
    def initialize(account, title)
      @account = account
      @title = title
    end

    attr_reader :account, :title
  end

  class Runner
    def initialize(my_accounts, heuristics)
      @my_accounts = my_accounts
      @heuristics = heuristics
    end

    def call(history)
      transactions = history.entries.map do |entry|
        result = run_for_one(entry)
        raise "Didnt found matching account for entry" if result.nil?
        Qif::Entry.new(
          entry.operation_date,
          entry.amount,
          result.account,
          result.title
        )
      end
      Qif::Package.new(my_accounts.fetch(history.account_number), transactions)
    end

    def run_for_one(imported_entry)
      matching_heuristic = heuristics.find do |heuristic|
        heuristic.call(imported_entry)
      end
      return matching_heuristic.call(imported_entry) unless matching_heuristic.nil?
    end

    attr_reader :my_accounts, :heuristics
  end
end

module Importers
  class Entry
    def initialize(operation_date, accounting_date, description, title, receiver, account, amount)
      @operation_date = operation_date
      @accounting_date = accounting_date
      @description = description
      @title = title
      @receiver = receiver
      @account = account
      @amount = amount
    end

    attr_reader :operation_date, :accounting_date, :description, :title, :receiver, :account, :amount
  end

  class History
    def initialize(account_number, entries)
      @account_number = account_number
      @entries = entries
    end

    attr_reader :account_number, :entries
  end

  class Mbank
    def import_from_file(csv_path)
      original_lines = CSV.readlines(csv_path, col_sep: ";", encoding: "Windows-1250:UTF-8")
      account_number_line = original_lines.index {|l| l[0] == "#Numer rachunku" } + 1
      account_number = original_lines[account_number_line][0].gsub(/[  ]/, "") # These are not two spaces, these are different blank characters

      first_transaction_line = original_lines.index {|l| l[0] == "#Data operacji" } + 1
      last_transaction_line = original_lines.rindex {|l| l[6] == "#Saldo końcowe" } - 1

      imported_entries = original_lines[first_transaction_line..last_transaction_line].reject(&:empty?).map do |operation_date, accounting_date, description, title, receiver, account, amount, _balance|
        amount_number = BigDecimal(amount.gsub(" ", "").gsub(",", "."))
        Entry.new(
          Date.parse(operation_date),
          Date.parse(accounting_date),
          description,
          title,
          receiver,
          account.gsub(/'/, ""),
          amount_number
        )
      end
      return Importers::History.new(account_number, imported_entries)
    end
  end
end

module Qif
  class Entry
    def initialize(date, amount, account, description)
      raise "date is not a Date" unless date.is_a?(Date)
      @date = date

      raise "amount is not BigDecimal" unless amount.is_a?(BigDecimal)
      @amount = amount

      @account = account
      @description = description
    end

    attr_reader :date, :amount, :account, :description
  end

  class Package
    def initialize(account_name, transactions)
      @account_name = account_name
      @transactions = transactions
    end

    attr_reader :account_name, :transactions
  end

  class Exporter
    def export_to_file(qif_package, export_file_path)
      raise "Is not a QIF package" unless qif_package.is_a?(Package)
      File.open(export_file_path, "w") do |f|
        f.puts export_to_string(qif_package)
      end
    end

    def export_to_string(qif_package)
      export = []

      export << "!Account"
      export << "N#{qif_package.account_name}"
      export << "^"

      export << "!Type:Bank"
      qif_package.transactions.each do |transaction|
        export << "D#{format_date(transaction.date)}"
        export << "T#{format_amount(transaction.amount)}"

        export << "L#{transaction.account}" unless transaction.account.nil?
        export << "P#{transaction.description}" unless transaction.description.nil?

        export << "^"
      end

      export.join("\n")
    end

    private
    def format_date(date)
      date.strftime("%d.%m'%Y")
    end

    def format_amount(amount)
      sprintf("%.2f", amount)
    end
  end
end

configuration_file = ARGV[0]
load configuration_file

importer = case ARGV[1]
  when "mbank" then Importers::Mbank.new
  else raise "Unknown importer"
end
csv_path = ARGV[2]
export_dir = ARGV[3]

history = importer.import_from_file(csv_path)
export_path = File.join(export_dir, "#{history.account_number}.qif")

package = Heuristics::Runner.new($my_accounts, $my_heuristics).call(history)

Qif::Exporter.new.export_to_file(package, export_path)

puts "Finished #{package.account_name}"

# TODO: maybe package step, with resulting balances?
