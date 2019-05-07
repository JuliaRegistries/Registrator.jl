# Version:0.0.1

FROM julia:latest

# install GIT
RUN apt-get update; apt-get install git -y

RUN useradd -ms /bin/bash registrator

USER registrator
WORKDIR /home/registrator

RUN julia -e "using Pkg; Pkg.add(PackageSpec(url=\"https://github.com/JuliaRegistries/Registrator.jl\"))"
ADD scripts /home/registrator

# Comment out ENTRYPOINT and uncomment the CMD line if you are using Heroku.
ENTRYPOINT ["/bin/bash", "run.sh"]
# CMD /bin/bash run.sh
