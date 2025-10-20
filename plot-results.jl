import JSON
import DataFrames
# import WGLMakie as Makie
import CairoMakie as Makie
import Unitful
import StatsBase
import Format

Makie.activate!(type = "svg")

struct Bench
    file::AbstractString
    device::AbstractString
    workload::AbstractString
    fs::AbstractString
end

struct Latencies
    bins::AbstractVector{Unitful.Quantity{Float64,Unitful.𝐓}}
end

struct LatencyBins
    num_jobs::Int
    latencies::Latencies
    weights::StatsBase.FrequencyWeights
end

struct IOPS
    min::Int
    max::Int
    mean::Real
    stddev::Real
    samples::Int
end

ALL_FILESYSTEMS =
    ["bcachefs", "bcachefs-no-checksum", "ext4", "ext4-no-journal", "xfs", "btrfs"]

function engineering_notation_suffix(exponent)::Char
    if exponent == 30
        return 'Q'
    end
    if exponent == 27
        return 'R'
    end
    if exponent == 24
        return 'Y'
    end
    if exponent == 21
        return 'Z'
    end
    if exponent == 18
        return 'E'
    end
    if exponent == 15
        return 'P'
    end
    if exponent == 12
        return 'T'
    end
    if exponent == 9
        return 'G'
    end
    if exponent == 6
        return 'M'
    end
    if exponent == 3
        return 'k'
    end
    if exponent == 0
        return ' '
    end
    if exponent == -3
        return 'm'
    end
    if exponent == -6
        return 'μ'
    end
    if exponent == -9
        return 'n'
    end
    if exponent == -12
        return 'p'
    end
    if exponent == -15
        return 'f'
    end
    if exponent == -18
        return 'a'
    end
    if exponent == -21
        return 'z'
    end
    if exponent == -24
        return 'y'
    end
    if exponent == -27
        return 'r'
    end
    if exponent == -30
        return 'q'
    end
    @assert false
end

function engineering_notation(value)
    @assert value >= 0
    (mantissa, exponent) = if value == 0
        (0, 0)
    else
        exponent = 3 * floor(log10(value) / 3)
        mantissa = value / (10^exponent)
        exponent = convert(Int, exponent)
        (mantissa, exponent)
    end
    (mantissa, engineering_notation_suffix(exponent))
end

function engineering_format(value::Real)
    DIGITS_TOTAL=4
    (mantissa, suffix) = engineering_notation(value)
    mantissa_ndigits = ndigits(convert(Int, floor(mantissa)), base = 10)
    precision = DIGITS_TOTAL-mantissa_ndigits
    Format.format(
        mantissa,
        precision = precision,
        stripzeros = true,
        suffix = string(suffix),
    )
end

function relative_difference(a, b)
    (b - a) / a
end

function parse_bench(file::String)::Bench
    filename = basename(file)
    (device, rest) = split(filename, '-'; limit = 2)
    for fs in ALL_FILESYSTEMS
        if !endswith(rest, fs)
            continue
        end
        workload = chopsuffix(rest, "-"*fs)
        return Bench(file, device, workload, fs)
    end
    error()
end

RESULTS_DIR = "/repositories/bcache-benchmarking_results-2025-10-16_033/"
FILES = cd(() -> readdir(join = true), RESULTS_DIR)
FILES = filter!(e -> begin
    filename = basename(e);
    !(filename == "full" || filename == "terse")
end, FILES)
BENCHES = parse_bench.(FILES)

df = DataFrames.DataFrame(
    device = AbstractString[],
    workload = AbstractString[],
    fs = AbstractString[],
    numjobs = Int[],
    metric = AbstractString[],
    latencies = LatencyBins[],
    iops = IOPS[],
)
for bench in BENCHES
    json = JSON.parsefile(bench.file)
    for job in json["jobs"]
        numjobs = if haskey(job["job options"], "numjobs")
            parse(Int, job["job options"]["numjobs"])
        else
            1
        end
        for (key, value) in job
            if !isa(value, AbstractDict) || !haskey(value, "clat_ns")
                continue
            end
            iops = IOPS(
                value["iops_min"],
                value["iops_max"],
                value["iops_mean"],
                value["iops_stddev"],
                value["iops_samples"],
            )
            value = value["clat_ns"]
            if !isa(value, AbstractDict) || !haskey(value, "bins")
                continue
            end
            value = value["bins"]
            @assert length(value) > 0
            latencies_ = let
                latencies::AbstractVector{Unitful.Quantity{Float64,Unitful.𝐓}} = []
                weights::AbstractVector{Real} = []
                sizehint!(latencies, length(value))
                sizehint!(weights, length(value))
                for (latency, times_seen::Real) in value
                    latency = parse(Float64, latency)
                    latency = latency*Unitful.u"ns"
                    latency = Unitful.upreferred(latency)
                    push!(latencies, latency)
                    push!(weights, times_seen)
                end
                latencies2 = Latencies(latencies)
                weights = StatsBase.FrequencyWeights(weights)
                LatencyBins(numjobs, latencies2, weights)
            end
            row = Dict()
            row["device"] = bench.device
            row["workload"] = bench.workload
            row["fs"] = bench.fs
            row["numjobs"] = numjobs
            row["metric"] = key
            row["latencies"] = latencies_
            row["iops"] = iops
            push!(df, row)
        end
    end
end

groups = [:device, :workload, :metric]
gdf = df
gdf = DataFrames.transform(gdf, :iops => ((IOPS) -> begin
    getfield.(IOPS, :mean)
end) => :iops_mean)
gdf = DataFrames.groupby(gdf, groups)
gdf = DataFrames.transform(
    gdf,
    DataFrames.groupindices => :group_id,
    :iops_mean =>
        ((IOPS) -> begin
            relative_difference.(maximum(IOPS), IOPS)
        end) => :iops_regression,
)
gdf_view = gdf
gdf_view = DataFrames.select(gdf_view, [:group_id, :iops_regression, :fs])
gdf_view = DataFrames.filter([:fs] => (fs) -> fs == "bcachefs", gdf_view)
gdf_view = DataFrames.select(gdf_view, [:group_id, :iops_regression])
gdf_view = DataFrames.sort!(gdf_view, DataFrames.order(:iops_regression, rev = true))
gdf_view = DataFrames.select(gdf_view, [:group_id])
gdf_view = DataFrames.transform(
    gdf_view,
    :group_id => ((group_id) -> begin
        eachindex(group_id)
    end) => :new_group_id,
)
gdf = DataFrames.innerjoin(gdf, gdf_view, on = :group_id)
gdf = DataFrames.sort(
    gdf,
    [DataFrames.order(:new_group_id), DataFrames.order(:iops_mean, rev = true)],
)
gdf = DataFrames.groupby(gdf, :new_group_id)

fig = Makie.Figure()
for (fig_index, group) in enumerate(gdf)
    categories = group[!, :fs]
    elts = 1:length(categories)

    bcachefs_idx = findfirst(e->e=="bcachefs", categories)

    fig_row = fig[fig_index, 1] = Makie.GridLayout()

    title = first(group[!, :workload]) * " (" * first(group[!, :metric]) * ")"
    title *= " (threads: " * string(first(group[!, :numjobs])) * ")"

    Makie.Label(
        fig[fig_index, 1, Makie.Top()],
        string(fig_index) * ". " * title,
        fontsize = 26,
        font = :bold,
        padding = (0, 5, 5, 0),
        halign = :left,
    )

    axis_latencies = Missing
    let
        xs::AbstractVector{Int} = []
        ys::AbstractVector{Unitful.Quantity{Float64,Unitful.𝐓}} = []
        ys_wts::AbstractVector{Real} = []
        for (index, value) in enumerate(group[!, :latencies])
            ys_part = value.latencies.bins
            ys_wts_part = value.weights
            xs_part = repeat([index], length(ys_part))

            xs = vcat(xs, xs_part)
            ys = vcat(ys, ys_part)
            ys_wts = vcat(ys_wts, ys_wts_part)
        end
        elts = 1:length(categories)
        ys_ = Unitful.ustrip.(Unitful.u"s", ys)

        axis_latencies =
            axis = Makie.Axis(
                fig_row[1, 2],
                ylabel = "Latencies, s (less is better)",
                yaxisposition = :right,
                xticks = (elts, categories),
                xticklabelrotation = pi/16,
                yscale = Makie.log10,
                width = 400,
                height = 300,
                ytickformat = ys_ -> [engineering_format(v) for v in ys_],
            )
        Makie.boxplot!(
            axis,
            xs,
            ys_,
            weights = ys_wts,
            show_notch = true,
            show_median = true,
            show_outliers = false,
            width = 1,
            whiskerwidth = 0.5,
            color = map(
                xs -> startswith(categories[xs], "bcachefs") ? (:black, 0.5) : :blue,
                xs,
            ),
        )
    end

    axis_iops = Missing
    let
        xs = elts
        ys = getfield.(group[!, :iops], :mean)
        ys_stddev = getfield.(group[!, :iops], :stddev)
        ys_min = getfield.(group[!, :iops], :min)
        ys_max = getfield.(group[!, :iops], :max)
        axis_iops =
            axis = Makie.Axis(
                fig_row[1, 1],
                yaxisposition = :left,
                ylabel = "IOPS (more is better)",
                xticks = (elts, categories),
                xticklabelrotation = pi/16,
                # yscale = Makie.log10,
                width = 400,
                height = 300,
                ytickformat = ys -> [engineering_format(v) for v in ys],
            )
        color =
            map(xs -> startswith(categories[xs], "bcachefs") ? (:black, 0.5) : :blue, xs)
        if false
            Makie.rangebars!(
                axis,
                xs,
                ys_min,
                ys_max,
                linewidth = 10,
                whiskerwidth = 20,
                color = color,
            )
        else
            Makie.errorbars!(
                axis,
                xs,
                ys,
                ys_stddev,
                linewidth = 10,
                whiskerwidth = 20,
                color = map(
                    xs -> startswith(categories[xs], "bcachefs") ? (:black, 0.5) : :blue,
                    xs,
                ),
            )
            Makie.scatter!(axis, xs, ys, marker = :hline, markersize = 30, color = color)
        end

        let
            best_IOPS = maximum(ys)
            bcachefs_IOPS = ys[bcachefs_idx]
            yticks = [best_IOPS, bcachefs_IOPS]
            axis2 = Makie.Axis(
                fig_row[1, 1],
                xtickformat = "",
                yaxisposition = :right,
                yticks = yticks,
                ytickformat = yticks -> [engineering_format(v) for v in yticks],
                yticksmirrored = true,
            )
            Makie.linkxaxes!(axis, axis2)
            Makie.linkyaxes!(axis, axis2)
            IOPS_gap = Format.format(
                "{:#0.1f}%",
                100*relative_difference(best_IOPS, bcachefs_IOPS),
            )
            Makie.scatter!(
                axis2,
                (1, best_IOPS),
                marker = :star5,
                alpha = 0.75,
                markersize = 10,
                color = :white,
            )
            Makie.hlines!(
                axis2,
                best_IOPS,
                alpha = 0.25,
                color = :green,
                linestyle = :dash,
                label = "best IOPS",
            )
            Makie.hlines!(
                axis2,
                bcachefs_IOPS,
                alpha = 0.25,
                color = :black,
                linestyle = :dash,
                label = "bcachefs IOPS",
            )
            Makie.bracket!(
                axis2,
                bcachefs_idx,
                best_IOPS,
                bcachefs_idx,
                bcachefs_IOPS,
                offset = 5,
                text = IOPS_gap,
                style = :square,
                color = :red,
                textcolor = :red,
                orientation = :down,
                font = :bold,
            )
        end
    end
    Makie.linkxaxes!(axis_latencies, axis_iops)
end
Makie.resize_to_layout!(fig)
Makie.save("/tmp/figure.png", fig)
Makie.save("/tmp/figure.pdf", fig)
display(fig)
