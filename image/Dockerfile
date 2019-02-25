# Version:0.0.1

FROM julia:latest

RUN useradd -ms /bin/bash registrator

USER registrator
WORKDIR /home/registrator

RUN julia -e "using Pkg; Pkg.add(PackageSpec(url=\"https://github.com/JuliaComputing/Registrator.jl\"))"
ADD scripts /home/registrator

ENTRYPOINT ["/bin/bash", "run.sh"]
