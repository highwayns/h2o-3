library(h2o)
h2o.init()

# Explore a typical Data Science workflow with H2O and R
#
# Goal: assist the manager of data of NYC to load-balance the bicycles
# across the data network of stations, by predicting the number of bike
# trips taken from the station every day.  Use 10 million rows of historical
# data, and eventually add weather data.

# Connect to a cluster
# Set this to True if you want to fetch the data directly from S3.
# This is useful if your cluster is running in EC2.
data_source_is_s3 = FALSE

locate_source <- function(s) {
  if (data_source_is_s3)
    myPath <- paste0("s3n://h2o-public-test-data/", s)
  else
    myPath <- h2o:::.h2o.locate(s)
}

# Get the big dataset for citi.
# Big data is 10M rows
large_test <-  c(locate_source("bigdata/laptop/citibike-nyc/2013-07.csv"),
                  locate_source("bigdata/laptop/citibike-nyc/2013-08.csv"),
                  locate_source("bigdata/laptop/citibike-nyc/2013-09.csv"),
                  locate_source("bigdata/laptop/citibike-nyc/2013-10.csv"),
                  locate_source("bigdata/laptop/citibike-nyc/2013-11.csv"),
                  locate_source("bigdata/laptop/citibike-nyc/2013-12.csv"),
                  locate_source("bigdata/laptop/citibike-nyc/2014-01.csv"),
                  locate_source("bigdata/laptop/citibike-nyc/2014-02.csv"),
                  locate_source("bigdata/laptop/citibike-nyc/2014-03.csv"),
                  locate_source("bigdata/laptop/citibike-nyc/2014-04.csv"),
                  locate_source("bigdata/laptop/citibike-nyc/2014-05.csv"),
                  locate_source("bigdata/laptop/citibike-nyc/2014-06.csv"),
                  locate_source("bigdata/laptop/citibike-nyc/2014-07.csv"),
                  locate_source("bigdata/laptop/citibike-nyc/2014-08.csv"))

# 1- Load data - 1 row per bicycle trip.  Has columns showing the start and end
# station, trip duration and trip start time and day.  The larger dataset
# totals about 10 million rows
print("Import and Parse bike data...")
start <- Sys.time()
data <- h2o.importFile(path = large_test, destination_frame = "citi_bike")
parseTime <- Sys.time() - start
print(paste("Took", round(parseTime, digits = 2), units(parseTime),"to parse",
            nrow(data), "rows and", ncol(data), "columns."))

# 2- light data munging: group the bike starts per-day, converting the 10M rows
# of trips to about 140,000 station&day combos - predicting the number of trip
# starts per-station-per-day.

print('Calculate the dates and day of week based on starttime')
secsPerDay <- 1000*60*60*24
starttime  <- data$starttime
data$days  <- floor(starttime/secsPerDay)
data$year  <- year(starttime) + 1900
data$month <- month(starttime)
data$dayofweek <- dayOfWeek(starttime)
data$day   <- day(starttime)
data$age   <- data$year - data$"birth year"

print ('Group data into station & day combinations...')
start <- Sys.time()
bpd <- h2o.group_by(data, by = c("days","start station name"), nrow("day") , mean("tripduration"), mean("age"))
groupTime <- Sys.time() - start
print(paste("Took", round(groupTime, digits = 2), units(groupTime), "to group",
            nrow(data), "data points into", nrow(bpd), "points."))
names(bpd) <- c("Days","start station name", "bike_count", "mean_duration", "mean_age")

# A little feature engineering
# Add in month-of-year (seasonality; fewer bike rides in winter than summer)
secs <- bpd$Days*secsPerDay
bpd$Month = as.factor(h2o.month(secs))
# Add in day-of-week (work-week; more bike rides on Sunday than Monday)
bpd$DayOfWeek = h2o.dayOfWeek(secs)


print('Examine the distribution of the number of bike rides as well as the average day of riders per day...')
print(quantile(bpd$bike_count))
print(quantile(bpd$mean_age))
print(h2o.hist(bpd$bike_count))
print(h2o.hist(bpd$mean_age))
print(summary(bpd))

# 3- Fit a model on train; using test as validation

# Function for doing class test/train/holdout split
split_fit_predict <- function(data) {
  r <- h2o.runif(data$Days,seed=1234)
  train <- data[r < 0.6,]
  test  <- data[(r >= 0.6) & (r < 0.9),]
  hold  <- data[r >= 0.9,]
  print(paste("Training data has", ncol(train), "columns and", nrow(train), "rows, test has",
              nrow(test), "rows, holdout has", nrow(hold)))

  myY <- "bike_count"
  myX <- setdiff(names(train), myY)

  # Run GBM
  gbm <- h2o.gbm(x = myX,
                 y = myY,
                 training_frame    = train,
                 validation_frame  = test,
                 ntrees            = 500,
                 max_depth         = 6,
                 learn_rate        = 0.1)

  # Run DRF
  drf <- h2o.randomForest(x = myX,
                          y = myY,
                          training_frame    = train,
                          validation_frame  = test,
                          ntrees            = 250,
                          max_depth         = 30)


  # Run GLM
  glm <- h2o.glm(x = myX,
                 y = myY,
                 training_frame    = train,
                 validation_frame  = test,
                 family            = "poisson")

  # 4- Score on holdout set & report
  train_logloss_gbm  <- h2o.logloss(gbm, train = TRUE)
  test_logloss_gbm   <- h2o.logloss(gbm, valid = TRUE)
  hold_perf_gbm <- h2o.performance(model = gbm, data = hold)
  hold_logloss_gbm   <- h2o.logloss(object = hold_perf_gbm)
  print(paste0("GBM logloss TRAIN = ", train_logloss_gbm, ", logloss TEST = ", test_logloss_gbm, ", logloss HOLDOUT = ",
               hold_logloss_gbm))

  train_logloss_drf  <- h2o.logloss(drf, train = TRUE)
  test_logloss_drf   <- h2o.logloss(drf, valid = TRUE)
  hold_perf_drf <- h2o.performance(model = drf, data = hold)
  hold_logloss_drf   <- h2o.logloss(object = hold_perf_drf)
  print(paste0("DRF logloss TRAIN = ", train_logloss_drf, ", logloss TEST = ", test_logloss_drf, ", logloss HOLDOUT = ",
               hold_logloss_drf))

  train_logloss_glm  <- h2o.logloss(glm, train = TRUE)
  test_logloss_glm   <- h2o.logloss(glm, valid = TRUE)
  hold_perf_glm <- h2o.performance(model = glm, data = hold)
  hold_logloss_glm   <- h2o.logloss(hold_perf_glm)
  print(paste0("GLM logloss TRAIN = ", train_logloss_glm, ", logloss TEST = ", test_logloss_glm, ", logloss HOLDOUT = ",
               hold_logloss_glm))
}

# Split the data (into test & train), fit some models and predict on the holdout data
start <- Sys.time()
split_fit_predict(bpd)
modelBuild <- Sys.time() - start
print(paste("Took", round(modelBuild, digits = 2), units(modelBuild), "to build a gbm, a random forest, and a glm model, score and report logloss values."))

# Here we see an r^2 of 0.91 for GBM, and 0.71 for GLM.  This means given just
# the station, the month, and the day-of-week we can predict 90% of the
# variance of the bike-trip-starts.

# 5- Now lets add some weather
# Load weather data
wthr1 <- h2o.importFile(path =
  c(locate_source("bigdata/laptop/citibike-nyc/31081_New_York_City__Hourly_2013.csv"),
    locate_source("bigdata/laptop/citibike-nyc/31081_New_York_City__Hourly_2014.csv")))

# Peek at the data
print(summary(wthr1))

# Lots of columns in there!  Lets plan on converting to time-since-epoch to do
# a 'join' with the bike data, plus gather weather info that might affect
# cyclists - rain, snow, temperature.  Alas, drop the "snow" column since it's
# all NA's.  Also add in dew point and humidity just in case.  Slice out just
# the columns of interest and drop the rest.
wthr2 <- wthr1[, c("Year Local","Month Local","Day Local","Hour Local","Dew Point (C)",
  "Humidity Fraction","Precipitation One Hour (mm)","Temperature (C)",
  "Weather Code 1/ Description")]
colnames(wthr2)[match("Precipitation One Hour (mm)", colnames(wthr2))] <- "Rain (mm)" # Shorter column name
names(wthr2)[match("Weather Code 1/ Description", colnames(wthr2))] <- "WC1" # Shorter column name
print(summary(wthr2))
# Much better!
# Filter down to the weather at Noon
wthr3 <- wthr2[ wthr2["Hour Local"]==12 ,]
# Also, most rain numbers are missing - lets assume those are zero rain days
wthr3[,"Rain (mm)"] <- ifelse(is.na(wthr3[,"Rain (mm)"]), 0, wthr3[,"Rain (mm)"])
names(wthr3) = c("year", "month", "day", names(wthr3)[4:9])

starttime = h2o.mktime(year=wthr3$year, month=wthr3$month-1, day=wthr3$day-1, hour=wthr3["Hour Local"])
wthr3$Days = floor(starttime/secsPerDay)


# 6 - Join the weather data-per-day to the bike-starts-per-day
print("Merge Daily Weather with Bikes-Per-Day")
bpd_with_weather <- h2o.merge(x = bpd, y = wthr3, all.x = T, all.y = F)
summary(bpd_with_weather)
print(bpd_with_weather)
dim(bpd_with_weather)

# 7 - Test/Train split again, model build again, this time with weather
start <- Sys.time()
split_fit_predict(bpd_with_weather)
modelBuild <- Sys.time() - start
print(paste("Took", round(modelBuild, digits = 2), units(modelBuild) ,"to build a gbm, a random forest, and a glm model, score and report r2 values."))
