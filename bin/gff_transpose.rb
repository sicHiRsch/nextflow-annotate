#!/usr/bin/env ruby

require 'optparse'
require 'ostruct'
require 'pathname'
require 'set'
require 'bio'
require 'pp'

class Options
  def self.parse(args)
    options = OpenStruct.new
    opts = OptionParser.new do |opts|
      opts.banner = "Usage: #{$0} [options] --from GFF --to GFF"
      opts.separator ""
      opts.separator "Specific options:"

      opts.on("-f", "--from FILENAME (Required)", "GFF file with features to transpose") do |filename|
        path = Pathname.new(filename)
        if path.exist?
          options.from = path
        else
          $stderr.puts("ERROR: Could not find the file #{filename}")
          $stderr.puts opts.banner
          exit(1)
        end
      end

      opts.on("-t", "--to FILENAME (Required)", "GFF file describing where the proteins are in nucleotide coorinates") do |filename|
        path = Pathname.new(filename)
        if path.exist?
          options.to = path
        else
          $stderr.puts("ERROR: Could not find the file #{filename}")
          $stderr.puts opts.banner
          exit(1)
        end
      end

    end
    opts.parse!(args)

    unless options.from
      $stderr.puts "Error: No *TO* GFF3 file supplied\n"
      $stderr.puts opts.banner
      exit(1)
    end

    unless options.to
      $stderr.puts "Error: No *FROM* GFF3 file supplied\n"
      $stderr.puts opts.banner
      exit(1)
    end

    options
  end
end
options = Options.parse(ARGV)

records_lookup = Bio::GFF::GFF3.new(File.read(options.to))
                 .records
                 .find_all{ |record| record.feature == "exon" }
                 .to_set
                 .classify{ |record| Hash[record.attributes]["Parent"].gsub('mRNA', 'exon_') }

File.open(options.from).take_while{ |line| line !~ /FASTA/ }.each do |line|
  next if line =~ /^#/

  seqid, source, type, hit_start, hit_stop, score, strand, phase, attributes = line.chomp.split("\t")
  hit_start = hit_start.to_i
  hit_stop = hit_stop.to_i

  begin
    records = records_lookup[seqid]
              .sort_by{ |record| record.start }
              .map{ |record| record.strand = "+" unless record.strand; record }
  rescue
    $stderr.puts "\n\nCould not find lookup for '#{seqid}'"
    exit(1)
  end
  
  exon_length = records.inject(0) do |mem, record|
    mem += record.end - record.start + 1
  end

  ranges = case [records.first.strand,strand].join
           when "++"
             [Range.new(hit_start - 1, hit_stop)]
           when "-+"
             [Range.new(exon_length - hit_stop, exon_length - hit_start)]
           when "+-"
             [Range.new(hit_start - 1, hit_stop - 1)]
           when "--"
             [Range.new(exon_length - hit_stop + 1, exon_length - hit_start)]
           end
           .map!{ |range| Range.new(range.first + records.first.start, range.last + records.first.start)}

  records
    .each_cons(2)
    .map{ |a, b| Range.new(a.end + 1, b.start - 1) }
    .reduce(ranges) do |mem, intron|
    size = intron.last - intron.first + 1
    mem.flat_map do |range|
      # Is there an overlap between this range and an intron?
      if (range.first <= intron.last) and (intron.first <= range.last)
        # If we introduce the intron, does the shifted range still overlap the intron location?
        if range.first + size <= intron.last
          # If so, make the new intron
          [Range.new(range.first, intron.first - 1), Range.new(intron.last + 1, intron.last + range.last - intron.first + 1)]
        else
          # If not, we can just move the region to the right by the intron size
          Range.new(range.first + size, range.last + size)
        end
      elsif intron.last < range.first
        # If there is no overlap and the region is still to the right, we move it right.
        Range.new(range.first + size, range.last + size)
      else
        range
      end
    end
  end.each do |range|
    next if source == "."
    puts [
      records.first.seqname,
      source,
      type,
      range.first,
      range.last,
      score,
      records.first.strand == strand ? "+" : "-",
      ".",
      attributes
    ].join("\t")
  end
end
